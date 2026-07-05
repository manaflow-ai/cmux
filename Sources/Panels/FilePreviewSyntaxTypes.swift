import Foundation

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
