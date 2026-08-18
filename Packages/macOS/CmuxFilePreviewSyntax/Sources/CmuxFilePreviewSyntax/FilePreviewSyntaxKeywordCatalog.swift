/// Common keyword vocabularies for the supported language families.
struct FilePreviewSyntaxKeywordCatalog: Sendable {
    func keywords(for language: FilePreviewSyntaxLanguage) -> Set<String> {
        switch language {
        case .swift:
            [
                "associatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "convenience", "default", "defer", "deinit", "didSet", "do",
                "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
                "infix", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
                "nonmutating", "open", "operator", "optional", "override", "postfix", "prefix",
                "private", "protocol", "public", "repeat", "required", "rethrows", "return",
                "self", "set", "some", "static", "struct", "subscript", "super", "switch",
                "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
                "where", "while", "willSet", "actor", "nonisolated", "any", "consuming",
                "borrowing", "package", "macro", "each",
            ]
        case .cFamily:
            c
        case .cpp:
            c.union([
                "alignas", "alignof", "and", "asm", "catch", "class", "concept", "constexpr",
                "const_cast", "decltype", "delete", "dynamic_cast", "explicit", "export",
                "friend", "mutable", "namespace", "new", "noexcept", "nullptr", "operator",
                "or", "private", "protected", "public", "reinterpret_cast", "requires",
                "static_assert", "static_cast", "template", "this", "throw", "try", "typeid",
                "typename", "using", "virtual", "co_await", "co_return", "co_yield", "not",
                "xor",
            ])
        case .objc:
            c.union([
                "id", "self", "super", "nil", "Nil", "YES", "NO", "BOOL", "instancetype",
                "interface", "implementation", "protocol", "property", "synthesize", "dynamic",
                "selector", "encode", "class", "end", "import", "autoreleasepool", "try",
                "catch", "finally", "throw", "synchronized", "weak", "strong", "nonatomic",
                "atomic", "copy", "assign", "retain", "readonly", "readwrite",
            ])
        case .java:
            [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
                "class", "const", "continue", "default", "do", "double", "else", "enum",
                "extends", "final", "finally", "float", "for", "goto", "if", "implements",
                "import", "instanceof", "int", "interface", "long", "native", "new", "package",
                "private", "protected", "public", "return", "short", "static", "strictfp",
                "super", "switch", "synchronized", "this", "throw", "throws", "transient",
                "try", "void", "volatile", "while", "var", "record", "sealed", "permits",
                "yield", "true", "false", "null",
            ]
        case .kotlin:
            [
                "abstract", "actual", "annotation", "as", "break", "by", "catch", "class",
                "companion", "const", "constructor", "continue", "crossinline", "data",
                "delegate", "do", "dynamic", "else", "enum", "expect", "external", "false",
                "final", "finally", "for", "fun", "get", "if", "import", "in", "infix", "init",
                "inline", "inner", "interface", "internal", "is", "lateinit", "noinline", "null",
                "object", "open", "operator", "out", "override", "package", "private",
                "protected", "public", "reified", "return", "sealed", "set", "super", "suspend",
                "tailrec", "this", "throw", "true", "try", "typealias", "val", "var", "vararg",
                "when", "where", "while",
            ]
        case .csharp:
            [
                "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char",
                "checked", "class", "const", "continue", "decimal", "default", "delegate", "do",
                "double", "else", "enum", "event", "explicit", "extern", "false", "finally",
                "fixed", "float", "for", "foreach", "goto", "if", "implicit", "in", "int",
                "interface", "internal", "is", "lock", "long", "namespace", "new", "null",
                "object", "operator", "out", "override", "params", "private", "protected",
                "public", "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof",
                "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
                "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using",
                "virtual", "void", "volatile", "while", "var", "async", "await", "dynamic",
                "nameof", "record", "when",
            ]
        case .javascript:
            javascript
        case .typescript:
            javascript.union([
                "abstract", "any", "as", "asserts", "declare", "enum", "implements",
                "interface", "infer", "is", "keyof", "namespace", "never", "private",
                "protected", "public", "readonly", "satisfies", "type", "unique", "unknown",
                "override", "out",
            ])
        case .python:
            [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield", "match", "case",
                "self", "cls",
            ]
        case .ruby:
            [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
                "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next",
                "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
                "then", "true", "undef", "unless", "until", "when", "while", "yield",
                "attr_accessor", "attr_reader", "attr_writer", "require", "require_relative",
                "include", "extend",
            ]
        case .go:
            [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var", "nil",
                "true", "false", "iota",
            ]
        case .rust:
            [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
                "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
                "union",
            ]
        case .php:
            [
                "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
                "clone", "const", "continue", "declare", "default", "do", "echo", "else",
                "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch",
                "endwhile", "enum", "extends", "final", "finally", "fn", "for", "foreach",
                "function", "global", "if", "implements", "include", "instanceof", "insteadof",
                "interface", "isset", "list", "match", "namespace", "new", "or", "print",
                "private", "protected", "public", "readonly", "require", "return", "static",
                "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor",
                "yield", "true", "false", "null",
            ]
        case .shell:
            [
                "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while",
                "until", "do", "done", "in", "function", "time", "coproc", "return", "exit",
                "break", "continue", "export", "local", "readonly", "declare", "typeset", "unset",
                "shift", "source", "alias", "set", "echo", "printf", "read", "cd", "test",
            ]
        case .sql:
            [
                "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case",
                "cast", "check", "column", "commit", "constraint", "create", "cross", "database",
                "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
                "foreign", "from", "full", "group", "having", "if", "in", "index", "inner",
                "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null",
                "on", "or", "order", "outer", "primary", "references", "right", "rollback",
                "select", "set", "table", "then", "transaction", "trigger", "union", "unique",
                "update", "using", "values", "view", "when", "where", "with",
            ]
        case .json:
            ["true", "false", "null"]
        case .yaml:
            ["true", "false", "null", "yes", "no", "on", "off"]
        case .toml, .ini:
            ["true", "false"]
        case .css:
            []
        }
    }

    private let c: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
        "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "NULL",
    ]

    private let javascript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "export", "extends", "false",
        "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
        "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try",
        "typeof", "undefined", "var", "void", "while", "with", "yield", "get", "set",
    ]
}
