/// A method's Objective-C type encoding (`method_getTypeEncoding`, Apple's
/// "Type Encodings"), without qualifiers and frame offsets: what it returns
/// and what each argument after `self` and `_cmd` is.
struct PrivateSignature: Equatable {
    /// How one value travels in a call: the property a function type and an
    /// implementation must agree on for the call to read what was passed.
    enum Kind: Equatable {
        case void
        /// An Objective-C object, class or block (`@`, `#`, `@?`).
        case object
        /// A C pointer (`^`, `*`).
        case pointer
        case selector
        /// An integer of this many bytes (`B c C s S i I l L q Q`; `l` and `L`
        /// are 32-bit in every Objective-C ABI, `long` is encoded `q`).
        case integer(bytes: Int)
        case float
        case double
        /// A C struct by its tag (`{CGSize=dd}` is `CGSize`).
        case structure(String)
        case other
    }

    /// The return type's code (`d`, `@`, `{CGSize=dd}`, ...).
    let returns: String
    /// The argument codes after `self` and `_cmd`.
    let arguments: [String]

    private static let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V", "A"]

    /// Parses a method type encoding such as `@24@0:8@16`; nil when it is
    /// not one (no `self` and `_cmd`, or a type that does not end). The
    /// encoding comes from a framework's runtime metadata, so it is read from
    /// the front of what is left, never by a computed position.
    init?(encoding: String) {
        var rest = Substring(encoding)
        var types: [String] = []
        while !rest.isEmpty {
            rest = rest.drop { Self.qualifiers.contains($0) }
            guard let end = Self.typeEnd(rest) else { return nil }
            types.append(String(rest.prefix(upTo: end)))
            rest = rest.suffix(from: end)
            // The frame size after the return type, the offset after each argument.
            if rest.first == "-" { rest = rest.dropFirst() }
            rest = rest.drop { $0.isASCII && $0.isNumber }
        }
        let fixed = types.prefix(3)
        guard fixed.count == 3, let returnCode = fixed.first, fixed.dropFirst().first.map(Self.kind(of:)) == .object,
              fixed.last == ":" else { return nil }
        returns = returnCode
        arguments = Array(types.dropFirst(3))
    }

    /// The end of the one type that starts `codes`; nil when it does not end.
    private static func typeEnd(_ codes: Substring) -> Substring.Index? {
        guard let first = codes.first else { return nil }
        let next = codes.dropFirst()
        switch first {
        case "^":
            return typeEnd(next.drop { qualifiers.contains($0) })
        case "@":
            if next.first == "?" {
                let block = next.dropFirst()
                // An extended block signature: @?<v@?@>.
                return block.first == "<" ? closing(block, open: "<", close: ">") : block.startIndex
            }
            // An extended object type: @"NSString".
            if next.first == "\"" {
                guard let quote = next.dropFirst().firstIndex(of: "\"") else { return nil }
                return next.suffix(from: quote).dropFirst().startIndex
            }
            return next.startIndex
        case "{": return closing(codes, open: "{", close: "}")
        case "(": return closing(codes, open: "(", close: ")")
        case "[": return closing(codes, open: "[", close: "]")
        case "b":
            return next.drop { $0.isASCII && $0.isNumber }.startIndex
        default:
            return next.startIndex
        }
    }

    /// The end of the `close` that matches the `open` starting `codes`.
    private static func closing(_ codes: Substring, open: Character, close: Character) -> Substring.Index? {
        var depth = 0
        for (index, code) in zip(codes.indices, codes) {
            if code == open { depth += 1 }
            if code == close {
                depth -= 1
                if depth == 0 { return codes.index(after: index) }
            }
        }
        return nil
    }

    static func kind(of code: String) -> Kind {
        guard let first = code.first else { return .other }
        switch first {
        case "v": return .void
        case "@", "#": return .object
        case "^", "*": return .pointer
        case ":": return .selector
        case "B", "c", "C": return .integer(bytes: 1)
        case "s", "S": return .integer(bytes: 2)
        case "i", "I", "l", "L": return .integer(bytes: 4)
        case "q", "Q": return .integer(bytes: 8)
        case "f": return .float
        case "d": return .double
        case "{": return .structure(String(code.dropFirst().prefix { $0 != "=" && $0 != "}" }))
        default: return .other
        }
    }

    /// Whether `code` travels as `expected`. A Core Foundation reference
    /// (`^{__IOSurface=}`) is an object: CF types are Objective-C objects.
    static func matches(_ code: String, _ expected: Kind) -> Bool {
        kind(of: code) == expected || (expected == .object && code.hasPrefix("^{__"))
    }

    /// Whether the method returns `returns` and takes exactly `arguments` after `self` and `_cmd`.
    func matches(returns expected: Kind, arguments expectedArguments: [Kind]) -> Bool {
        Self.matches(returns, expected) && arguments.count == expectedArguments.count
            && zip(arguments, expectedArguments).allSatisfy { Self.matches($0, $1) }
    }
}
