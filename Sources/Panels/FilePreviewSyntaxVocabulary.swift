import Foundation

/// Keyword vocabularies per language family. Kept intentionally broad rather
/// than grammar-exact; highlighting only needs to recognize common keywords.
enum FilePreviewSyntaxKeywords {
    static let swift: Set<String> = [
        "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else",
        "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
        "get", "guard", "if", "import", "in", "indirect", "infix", "init", "inout", "internal",
        "is", "lazy", "let", "mutating", "nil", "nonmutating", "open", "operator", "optional",
        "override", "postfix", "prefix", "private", "protocol", "public", "repeat", "required",
        "rethrows", "return", "self", "set", "some", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
        "where", "while", "willSet", "actor", "nonisolated", "any", "consuming", "borrowing",
        "package", "macro", "each"
    ]

    static let c: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
        "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "NULL"
    ]

    static let cpp: Set<String> = c.union([
        "alignas", "alignof", "and", "asm", "catch", "class", "concept", "constexpr",
        "const_cast", "decltype", "delete", "dynamic_cast", "explicit", "export", "friend",
        "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "or", "private",
        "protected", "public", "reinterpret_cast", "requires", "static_assert", "static_cast",
        "template", "this", "throw", "try", "typeid", "typename", "using", "virtual", "co_await",
        "co_return", "co_yield", "not", "xor"
    ])

    static let objc: Set<String> = c.union([
        "id", "self", "super", "nil", "Nil", "YES", "NO", "BOOL", "instancetype",
        "interface", "implementation", "protocol", "property", "synthesize", "dynamic",
        "selector", "encode", "class", "end", "import", "autoreleasepool", "try", "catch",
        "finally", "throw", "synchronized", "weak", "strong", "nonatomic", "atomic", "copy",
        "assign", "retain", "readonly", "readwrite"
    ])

    static let java: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
        "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
        "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "native", "new", "package", "private", "protected", "public",
        "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record",
        "sealed", "permits", "yield", "true", "false", "null"
    ]

    static let kotlin: Set<String> = [
        "abstract", "actual", "annotation", "as", "break", "by", "catch", "class", "companion",
        "const", "constructor", "continue", "crossinline", "data", "delegate", "do", "dynamic",
        "else", "enum", "expect", "external", "false", "final", "finally", "for", "fun", "get",
        "if", "import", "in", "infix", "init", "inline", "inner", "interface", "internal", "is",
        "lateinit", "noinline", "null", "object", "open", "operator", "out", "override", "package",
        "private", "protected", "public", "reified", "return", "sealed", "set", "super", "suspend",
        "tailrec", "this", "throw", "true", "try", "typealias", "val", "var", "vararg", "when",
        "where", "while"
    ]

    static let csharp: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
        "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
        "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
        "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
        "long", "namespace", "new", "null", "object", "operator", "out", "override", "params",
        "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
        "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
        "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual",
        "void", "volatile", "while", "var", "async", "await", "dynamic", "nameof", "record", "when"
    ]

    static let javascript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
        "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return",
        "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
        "var", "void", "while", "with", "yield", "get", "set"
    ]

    static let typescript: Set<String> = javascript.union([
        "abstract", "any", "as", "asserts", "declare", "enum", "implements", "interface",
        "infer", "is", "keyof", "namespace", "never", "private", "protected", "public",
        "readonly", "satisfies", "type", "unique", "unknown", "override", "out"
    ])

    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
        "True", "try", "while", "with", "yield", "match", "case", "self", "cls"
    ]

    static let ruby: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
        "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
        "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
        "unless", "until", "when", "while", "yield", "attr_accessor", "attr_reader",
        "attr_writer", "require", "require_relative", "include", "extend"
    ]

    static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "iota"
    ]

    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
        "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while", "union"
    ]

    static let php: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone",
        "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty",
        "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "extends",
        "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements",
        "include", "instanceof", "insteadof", "interface", "isset", "list", "match", "namespace",
        "new", "or", "print", "private", "protected", "public", "readonly", "require", "return",
        "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor", "yield",
        "true", "false", "null"
    ]

    static let shell: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until",
        "do", "done", "in", "function", "time", "coproc", "return", "exit", "break", "continue",
        "export", "local", "readonly", "declare", "typeset", "unset", "shift", "source", "alias",
        "set", "echo", "printf", "read", "cd", "test"
    ]

    static let sql: Set<String> = [
        "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "cast",
        "check", "column", "commit", "constraint", "create", "cross", "database", "default",
        "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full",
        "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join", "key",
        "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "primary",
        "references", "right", "rollback", "select", "set", "table", "then", "transaction",
        "trigger", "union", "unique", "update", "using", "values", "view", "when", "where", "with"
    ].union([
        "ADD", "ALL", "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CAST",
        "CHECK", "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "DATABASE", "DEFAULT",
        "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FOREIGN", "FROM", "FULL",
        "GROUP", "HAVING", "IF", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "KEY",
        "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "PRIMARY",
        "REFERENCES", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN", "TRANSACTION",
        "TRIGGER", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "VIEW", "WHEN", "WHERE", "WITH"
    ])
}

/// Builtin / standard type names highlighted distinctly from keywords.
enum FilePreviewSyntaxTypes {
    static let swift: Set<String> = [
        "Any", "AnyObject", "Array", "Bool", "CGFloat", "Character", "Codable", "Decodable",
        "Dictionary", "Double", "Encodable", "Error", "Float", "Int", "Int8", "Int16", "Int32",
        "Int64", "Never", "Optional", "Result", "Sendable", "Set", "String", "Substring", "UInt",
        "UInt8", "UInt16", "UInt32", "UInt64", "Void", "Data", "Date", "URL", "UUID", "Task"
    ]

    static let c: Set<String> = [
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "wchar_t", "char16_t",
        "char32_t", "FILE", "va_list"
    ]

    static let java: Set<String> = [
        "Boolean", "Byte", "Character", "Double", "Float", "Integer", "Long", "Object", "Short",
        "String", "StringBuilder", "List", "Map", "Set", "Optional", "Exception", "Runnable",
        "Thread", "Override", "Void"
    ]

    static let csharp: Set<String> = [
        "Boolean", "Byte", "Char", "Decimal", "Double", "Int16", "Int32", "Int64", "Object",
        "Single", "String", "Task", "List", "Dictionary", "IEnumerable", "Action", "Func",
        "Exception", "Nullable"
    ]

    static let javascript: Set<String> = [
        "Array", "Boolean", "Date", "Error", "Function", "JSON", "Map", "Math", "Number",
        "Object", "Promise", "Proxy", "RegExp", "Set", "String", "Symbol", "WeakMap", "WeakSet",
        "BigInt", "console", "window", "document"
    ]

    static let typescript: Set<String> = javascript.union([
        "Record", "Partial", "Required", "Readonly", "Pick", "Omit", "Exclude", "Extract",
        "ReturnType", "Parameters", "Awaited", "NonNullable", "string", "number", "boolean",
        "object", "symbol", "bigint", "unknown", "never", "void", "any"
    ])

    static let python: Set<String> = [
        "bool", "bytes", "complex", "dict", "float", "frozenset", "int", "list", "object",
        "set", "str", "tuple", "type", "bytearray", "range", "Optional", "List", "Dict", "Tuple",
        "Set", "Any", "Union", "Callable", "Iterator", "Iterable", "Sequence", "Mapping"
    ]

    static let ruby: Set<String> = [
        "Array", "Hash", "String", "Symbol", "Integer", "Float", "Object", "Class", "Module",
        "Proc", "Range", "Struct", "Comparable", "Enumerable", "Kernel", "NilClass", "TrueClass",
        "FalseClass"
    ]

    static let go: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8",
        "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32",
        "uint64", "uintptr", "any"
    ]

    static let rust: Set<String> = [
        "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8",
        "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option", "Result", "Box", "Rc",
        "Arc", "Cell", "RefCell", "HashMap", "HashSet", "BTreeMap", "Self"
    ]

    static let php: Set<String> = [
        "int", "float", "string", "bool", "array", "object", "callable", "iterable", "void",
        "mixed", "null", "self", "static", "parent", "true", "false"
    ]

    static let sql: Set<String> = [
        "int", "integer", "bigint", "smallint", "tinyint", "decimal", "numeric", "float", "real",
        "double", "char", "varchar", "text", "nchar", "nvarchar", "date", "time", "datetime",
        "timestamp", "boolean", "bool", "blob", "json", "jsonb", "uuid", "serial",
        "INT", "INTEGER", "BIGINT", "SMALLINT", "DECIMAL", "NUMERIC", "FLOAT", "REAL", "DOUBLE",
        "CHAR", "VARCHAR", "TEXT", "DATE", "TIME", "DATETIME", "TIMESTAMP", "BOOLEAN", "BLOB",
        "JSON", "JSONB", "UUID", "SERIAL"
    ]
}
