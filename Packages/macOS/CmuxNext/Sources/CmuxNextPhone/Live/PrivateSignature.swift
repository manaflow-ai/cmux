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
    /// not one (no `self` and `_cmd`, or a type that does not end).
    init?(encoding: String) {
        let codes = Array(encoding)
        var types: [String] = []
        var index = 0
        while index < codes.count {
            var start = index
            while start < codes.count, Self.qualifiers.contains(codes[start]) { start += 1 }
            guard let end = Self.typeEnd(codes, from: start) else { return nil }
            types.append(String(codes[start..<end]))
            index = end
            // The frame size after the return type, the offset after each argument.
            if index < codes.count, codes[index] == "-" { index += 1 }
            while index < codes.count, codes[index].isASCII, codes[index].isNumber { index += 1 }
        }
        guard types.count >= 3, Self.kind(of: types[1]) == .object, types[2] == ":" else { return nil }
        returns = types[0]
        arguments = Array(types[3...])
    }

    /// The index after the one type that starts at `start`.
    private static func typeEnd(_ codes: [Character], from start: Int) -> Int? {
        guard start < codes.count else { return nil }
        switch codes[start] {
        case "^":
            var pointee = start + 1
            while pointee < codes.count, qualifiers.contains(codes[pointee]) { pointee += 1 }
            return typeEnd(codes, from: pointee)
        case "@":
            var end = start + 1
            if end < codes.count, codes[end] == "?" {
                end += 1
                // An extended block signature: @?<v@?@>.
                if end < codes.count, codes[end] == "<" { return closing(codes, from: end, open: "<", close: ">") }
                return end
            }
            // An extended object type: @"NSString".
            if end < codes.count, codes[end] == "\"" {
                guard let quote = codes[(end + 1)...].firstIndex(of: "\"") else { return nil }
                end = quote + 1
            }
            return end
        case "{": return closing(codes, from: start, open: "{", close: "}")
        case "(": return closing(codes, from: start, open: "(", close: ")")
        case "[": return closing(codes, from: start, open: "[", close: "]")
        case "b":
            var end = start + 1
            while end < codes.count, codes[end].isASCII, codes[end].isNumber { end += 1 }
            return end
        default:
            return start + 1
        }
    }

    /// The index after the `close` that matches the `open` at `start`.
    private static func closing(_ codes: [Character], from start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        for index in start..<codes.count {
            if codes[index] == open { depth += 1 }
            if codes[index] == close {
                depth -= 1
                if depth == 0 { return index + 1 }
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
