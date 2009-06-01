
module("lb", package.seeall)

require "lfs"

LBDEBUG = false

local action_type = 0		-- 'compile' or 'clean'
local lbfile = nil		-- content of luabuild file
local compile_type = 0		-- 'program' or 'share library'
local compile_params = {}	-- input parameters
local compile_string = ""
local link_string = ""

-----------------------------------------------------
-- This program's usage
--
-----------------------------------------------------
function usage()
	print("|  Usage:           ")
	print("|         lb [clean]")
	print("|                   ")
end

-----------------------------------------------------
-- Filter the input arguments
--
-----------------------------------------------------
function params_filter()
	if #arg > 1 then 
		print("Too many arguments.")	
		os.exit(1)
	end
	if arg[1] == "clean" then 
		action_type = 1 
		if LBDEBUG then print(arg[1]); print(action_type) end
		return true
	end
	-- if arg[1] have value, then
	if arg[1] then
		print("Unknown action type.")
		os.exit(1)
	end
end



function filetime(f)
	local attrib, err = lfs.attributes(f)
	if attrib then
		return attrib.modification
	else
		return 0
	end
end

function binfile()
	local name
	if compile_type == 0 then
		name = compile_params.name
	elseif compile_type == 1 then
		name = compile_params.name..".so"
	end
	
	return name
end

function bintime()
	local name = binfile()
	if name then
		return filetime(name)
	else
		return 0
	end
end


function checktime(f)
	local part = f:match("(.+)%.c$")
	local objfile = part..'.o'
	local c_filetime = filetime(f)
	local o_filetime = filetime(objfile)
	if not exists(objfile) then 
		-- print("corresponding object file doesn't exist.")
		return true 
	end
	
	if c_filetime > o_filetime then
		return true
	else
		return false
	end
end

function check_objtime(t)
	local bin_time = bintime()
	local flag = false
	for _, v in ipairs(t) do
		if filetime(v) > bin_time then
			flag = true
			break
		end	
	end
	
	if flag then return true
	else return false
	end
end

-----------------------------------------------------
-- retrieve the char of a string at index i
--
-----------------------------------------------------
local function at(s,i)
        return s:sub(i,i) 
end

-----------------------------------------------------
-- given a path @path, return the directory part and a file part.
-- if there's no directory part, the first value will be empty   
-- 
-----------------------------------------------------
function splitpath(path)
        local i = #path 
        local ch = at(path,i)
        while i > 0 and ch ~= '/' and ch ~= '\\' do
                i = i - 1
                ch = at(path,i)
        end
        if i == 0 then
                return '',path
        else
                return path:sub(1,i-1), path:sub(i+1)
        end
end

-----------------------------------------------------
-- split a comma string into separate parts and insert into a table, last return that table 
--
-----------------------------------------------------
function split_text(text)
        local t = {}
	while text and text ~= "" do
                local _, tail, substr = text:find("%s*([_%w%.%-%*/]+)%s*[,]?")
                
                if substr then 
                        table.insert( t, substr )
                else 
                        print("failed to split this string.")
                        os.exit(1)
                end
                text = text:sub(tail+1, -1)
        end

	return t
end

-----------------------------------------------------
-- expand the expression of '*.c' to each real c file with name
-- and remove '*.c' when finished
-- 
-----------------------------------------------------
function match_files( t, i, d )
	if d ~= '.' then lfs.chdir(d) end
	for f in lfs.dir('.') do
		if f ~= '.' and f ~= '..' then
		if f:find(".+%.c") then
			-- judge wheher have already one file with the same name
			-- may be not very effective
			local over_file = 0
			for i, v in ipairs(t) do
				if v == f then 
					over_file = 1
					break
				end
			end
			if over_file == 0 then
				table.insert(t, f)
			end
		end	
		end
	end
	table.remove(t, i)
	if d ~= '.' then lfs.chdir('..') end
end

-----------------------------------------------------
-- parse the src string, split it to separate files and generate a table like the following:
-- original:  src_str = "*.c, applet/*.c"
-- after transforming:
-- file_table = {
--	"a.c",
--	"b.c",
--	applet = {
--		d.c,
--		e.c
--	}
-- }
--
-----------------------------------------------------
function parse_src()
	local src_str = compile_params.src
	local file_table = {}
	-- first walk around
	file_table = split_text(src_str)
	if LBDEBUG then
		for k, v in pairs(file_table) do 
			print("file_table:1: ", k, v)
		end
	end
	
	-- second walk around: check '/'
	for i, v in ipairs(file_table) do
		if v:find("/") then
			local path, file_name = splitpath(v)
			if LBDEBUG then
				print(path, file_name)
			end
			if not file_table[path] then
				file_table[path] = {}
			end	
			table.insert( file_table[path], file_name )
			table.remove( file_table, i )
		end
	end

	if LBDEBUG then
		for k, v in pairs(file_table) do 
			print("file_table:2: ", k, v)
		end
	end
	
	-- third walk around: check '*'
	for k, v in pairs(file_table) do
		if type(k) == "number" then
			if v:find("%*") then
				match_files(file_table, k, '.')
			end
		elseif type(k) == "string" then
			for ii, vv in ipairs(file_table[k]) do
				if vv:find("%*") then
					match_files(file_table[k], ii, k)
				end
			end
		end
	end

	if LBDEBUG then
		for k, v in pairs(file_table) do 
			print("file_table:3: ", k, v)
		end
	end
	
	return file_table
end

-----------------------------------------------------
-- parse include dir string
--
-----------------------------------------------------
function parse_incdir( incdir )
	local t = {}
	local incdir = incdir or "/usr/include"
	
	t = split_text( incdir )
	
	for i, _ in ipairs(t) do
		t[i] = "-I"..t[i]
	end
	
	return table.concat(t, " ")
end

-----------------------------------------------------
-- parse lib dir string
--
-----------------------------------------------------
function parse_libdir( libdir )
	local t = {}
	local libdir = libdir or "/usr/lib"
	
	t = split_text( libdir )
	
	for i, _ in ipairs(t) do
		t[i] = "-L"..t[i]
	end

	return table.concat(t, " ")
end

-----------------------------------------------------
-- parse libs string
--
-----------------------------------------------------
function parse_libs( libs )
	local t = {}
	local libs = libs or ""
	
	t = split_text( libs )
	
	for i, _ in ipairs(t) do
		t[i] = "-l"..t[i]
	end

	return table.concat(t, " ")
end

-----------------------------------------------------
-- parse defines string
--
-----------------------------------------------------
function parse_defines( defines )
	local t = {}
	local defines = defines or " "
	
	t = split_text( libdir )
	
	for i, _ in ipairs(t) do
		t[i] = "-D"..t[i]
	end

	return table.concat(t, " ")
end

-----------------------------------------------------
-- parse cflags string
--
-----------------------------------------------------
function parse_cflags( cflags )
	local t = {}
	local cflags = cflags or "g"
	
	t = split_text( cflags )
	
	for i, _ in ipairs(t) do
		t[i] = "-"..t[i]
	end

	return table.concat(t, " ")
end

-----------------------------------------------------
-- parse compiler string
--
-----------------------------------------------------
function parse_compiler( compiler )
	local compiler = compiler or "gcc"
	return compiler

end

-----------------------------------------------------
-- parse linker string
--
-----------------------------------------------------
function parse_linker( linker )
	local linker = linker or "gcc"
	return linker

end

-----------------------------------------------------
-- parse object name string
--
-----------------------------------------------------
function parse_objname( objname )
	local objname = objname or "output_file"
	return objname

end

-----------------------------------------------------
-- parse compile parameters table
--
-----------------------------------------------------
function parse_compile_params()
	-- string
	local incdir = parse_incdir(compile_params.incdir)
	if LBDEBUG then print(incdir) end
	-- string
	local libdir = parse_libdir(compile_params.libdir)
	if LBDEBUG then print(libdir) end
	-- string
	local libs = parse_libs(compile_params.libs)
	if LBDEBUG then print(libs) end
	-- string
	local defines = parse_defines(compile_params.defines)
	if LBDEBUG then print(defines) end
	-- string
	local cflags = parse_cflags(compile_params.cflags)
	if LBDEBUG then print(cflags) end
	-- string
	local compiler = parse_compiler(compile_params.compiler)
	if LBDEBUG then print(compiler) end
	-- string
	local linker = parse_linker(compile_params.linker)
	if LBDEBUG then print(linker) end
	-- string
	local objname = parse_objname(compile_params.name)
	if LBDEBUG then print(objname) end

	compile_string = compiler.." -c "..cflags.." "..incdir.." "
	if compile_type == 0 then
		link_string = linker.." "..libdir.." "..libs.." -o "..objname.." "
	elseif compile_type == 1 then
		link_string = linker.." "..libdir.." "..libs.." -shared -o "..objname..".so "
	end
	
	-- table
	-- complex, check src parsing's success
	file_table = parse_src(compile_params.src)

	return file_table
end

--
--
--
function exists(f)
	return (lfs.attributes(f) ~= nil)

end

function is_table_empty(t)
	local count = 0
	for i, v in ipairs(t) do
		print(i, v)
		count = count + 1
	end
	
	if count > 0 then return true
	else return false
	end
end

-----------------------------------------------------
-- load lbfile
--
-----------------------------------------------------
function parse_lbfile()
	if not exists("lbfile") then
		print("boufile doesn't exist.")
		os.exit(1)
	end
	-- check if could load lbfile successfully
	if not loadfile("lbfile") then
		print("Syntax error in lbfile.")
		os.exit(1)
	end
	-- execute that script file, push variable into global environment
	dofile("lbfile")

	-- if language is c
	if program then
		-- compile to a binary executed file
--		if LBDEBUG then print(type(program)); for k, v in pairs(program) do print(k, v) end end
		compile_type = 0
		compile_params = program
	elseif shared_lib then
		-- compile to share library
		compile_type = 1
		compile_params = shared_lib
	end
	
	-- no compile infos
	if is_table_empty(compile_params) then
		print("Empty compiling params, leave out.")
		os.exit(1)
	end

	return parse_compile_params()
end

-----------------------------------------------------
-- compile those files in specified directory
--
-----------------------------------------------------
function recurse_compile(t, d)
	if d ~= '.' then lfs.chdir(d) end
	for k, v in pairs(t) do
		if type(k) == "number" then
			-- it's a file, execute compilation here
			if checktime(v) then
				local str = compile_string .. v
				print(str)
				os.execute(str)	
			end	
		elseif type(k) == "string" then
			-- it's a direcotry, recurse
			recurse_compile(v, k)
		end
	end
	if d ~= '.' then lfs.chdir('..') end
end

-----------------------------------------------------
-- do compile action
--
-----------------------------------------------------
function apply_compile( t )
	recurse_compile( t, '.' )
end

-----------------------------------------------------
-- find the .o files in the specified directory recursedly
--
-----------------------------------------------------
local predir = "./"
local olddir = "./"
function recurse_objs(t, d, file_table)
        if d ~= '.' then 
        	olddir = predir
        	predir = predir .. d .. '/'
        	lfs.chdir(d) 
        end
        for f in lfs.dir('.') do
                if f ~= '.' and f ~= '..' then
			aa = lfs.attributes(f)
			if aa then
				if aa.mode == "directory" then
					-- if that name is a directory, recurse
					if file_table[f] then
						recurse_objs(t, f, file_table)
					end
				elseif aa.mode == "file" then
					-- if that name is a file, insert it into table t if it's .o file
					if f:find(".+%.o") then
						table.insert(t, predir..f)
					end
				end     
			else
				print('failed to collect .o files.')
				os.exit(1)
			end
                end
        end
        if d ~= '.' then 
        	-- if lua recurse if real recurse, lua will restore the value of olddir and predir in every layer 
        	-- if not, we need to think of another way
        	predir = olddir
        	lfs.chdir('..') 
        end
end

-----------------------------------------------------
-- do link action
--
-----------------------------------------------------
function apply_link( file_table )
	local objfile_table = {} 	
	recurse_objs(objfile_table, '.', file_table)
	local str = table.concat(objfile_table, " ")

	if check_objtime(objfile_table) then
		str = link_string .. str
		-- execute link
		print(str)
		os.execute(str)
	else
		print("Up to date.")
	end
end

--
-- do clean action
--
function recurse_clean(d)
        if d ~= '.' then lfs.chdir(d) end
        for f in lfs.dir('.') do
                if f ~= '.' and f ~= '..' then
			aa = lfs.attributes(f)
			if aa then
				if aa.mode == "directory" then
					-- if that name is a directory, recurse
					recurse_clean(f)
				elseif aa.mode == "file" then
					-- if that name is a file, insert it into table t if it's .o file
					if f:find(".+%.o") then
						local str = "rm "..f
						print(str)
						os.execute( str )
					end
				end     
			else
				print('failed to collect .o files.')
				os.exit(1)
			end
                end
        end
        if d ~= '.' then lfs.chdir('..') end

end

function apply_clean()
	recurse_clean('.')
	local name = binfile()
	if name and exists(name) then os.execute("rm "..name) end
end

-----------------------------------------------------
-- main entry
-- 
-----------------------------------------------------
function run()
	--
	-- filter input parameters
	--
	params_filter()
	--
	-- read the lbfile and 
	--
	local file_table = parse_lbfile()
	if LBDEBUG then
		for k, v in pairs(file_table) do
			print("file_table:", k, v)
		end
	end
	
	if action_type == 1 then
		apply_clean()
		return true
	end

	apply_compile( file_table )
	apply_link( file_table )
		
	return true
end

