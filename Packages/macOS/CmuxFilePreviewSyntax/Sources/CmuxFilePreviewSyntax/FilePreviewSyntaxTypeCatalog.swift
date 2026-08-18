/// Common built-in and standard-library type names for supported languages.
struct FilePreviewSyntaxTypeCatalog: Sendable {
    func types(for language: FilePreviewSyntaxLanguage) -> Set<String> {
        switch language {
        case .swift:
            [
                "Any", "AnyObject", "Array", "Bool", "CGFloat", "Character", "Codable",
                "Decodable", "Dictionary", "Double", "Encodable", "Error", "Float", "Int",
                "Int8", "Int16", "Int32", "Int64", "Never", "Optional", "Result", "Sendable",
                "Set", "String", "Substring", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                "Void", "Data", "Date", "URL", "UUID", "Task",
            ]
        case .cFamily, .cpp:
            c
        case .objc:
            c.union([
                "Class", "SEL", "IMP", "NSInteger", "NSUInteger", "CGFloat", "NSObject",
                "NSString", "NSMutableString", "NSArray", "NSMutableArray", "NSDictionary",
                "NSMutableDictionary", "NSNumber", "NSData", "NSError", "NSNotification",
                "CGRect", "CGSize", "CGPoint",
            ])
        case .java, .kotlin:
            [
                "Boolean", "Byte", "Character", "Double", "Float", "Integer", "Long", "Object",
                "Short", "String", "StringBuilder", "List", "Map", "Set", "Optional",
                "Exception", "Runnable", "Thread", "Override", "Void",
            ]
        case .csharp:
            [
                "Boolean", "Byte", "Char", "Decimal", "Double", "Int16", "Int32", "Int64",
                "Object", "Single", "String", "Task", "List", "Dictionary", "IEnumerable",
                "Action", "Func", "Exception", "Nullable",
            ]
        case .javascript:
            javascript
        case .typescript:
            javascript.union([
                "Record", "Partial", "Required", "Readonly", "Pick", "Omit", "Exclude",
                "Extract", "ReturnType", "Parameters", "Awaited", "NonNullable", "string",
                "number", "boolean", "object", "symbol", "bigint", "unknown", "never", "void",
                "any",
            ])
        case .python:
            [
                "bool", "bytes", "complex", "dict", "float", "frozenset", "int", "list",
                "object", "set", "str", "tuple", "type", "bytearray", "range", "Optional", "List",
                "Dict", "Tuple", "Set", "Any", "Union", "Callable", "Iterator", "Iterable",
                "Sequence", "Mapping",
            ]
        case .ruby:
            [
                "Array", "Hash", "String", "Symbol", "Integer", "Float", "Object", "Class",
                "Module", "Proc", "Range", "Struct", "Comparable", "Enumerable", "Kernel",
                "NilClass", "TrueClass", "FalseClass",
            ]
        case .go:
            [
                "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
                "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
                "uint32", "uint64", "uintptr", "any",
            ]
        case .rust:
            [
                "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize",
                "str", "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option",
                "Result", "Box", "Rc", "Arc", "Cell", "RefCell", "HashMap", "HashSet",
                "BTreeMap", "Self",
            ]
        case .php:
            [
                "int", "float", "string", "bool", "array", "object", "callable", "iterable",
                "void", "mixed", "null", "self", "static", "parent", "true", "false",
            ]
        case .sql:
            [
                "int", "integer", "bigint", "smallint", "tinyint", "decimal", "numeric", "float",
                "real", "double", "char", "varchar", "text", "nchar", "nvarchar", "date", "time",
                "datetime", "timestamp", "boolean", "bool", "blob", "json", "jsonb", "uuid",
                "serial",
            ]
        case .shell, .css, .json, .yaml, .toml, .ini:
            []
        }
    }

    private let c: Set<String> = [
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
        "uint64_t", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "wchar_t",
        "char16_t", "char32_t", "FILE", "va_list",
    ]

    private let javascript: Set<String> = [
        "Array", "Boolean", "Date", "Error", "Function", "JSON", "Map", "Math", "Number",
        "Object", "Promise", "Proxy", "RegExp", "Set", "String", "Symbol", "WeakMap",
        "WeakSet", "BigInt", "console", "window", "document",
    ]
}
