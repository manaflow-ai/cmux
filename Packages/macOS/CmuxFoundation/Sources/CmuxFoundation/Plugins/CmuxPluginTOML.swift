import Foundation

/// A value from the TOML subset accepted in `cmux-plugin.toml`.
///
/// Plugin manifests only need strings, integers, booleans, arrays, and
/// tables, so floats, dates, and multi-line strings are rejected instead of
/// being half-supported.
public enum CmuxPluginTOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([CmuxPluginTOMLValue])
    case table([String: CmuxPluginTOMLValue])
}

/// A TOML syntax error with the 1-based line where parsing stopped.
public struct CmuxPluginTOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public var description: String { "line \(line): \(message)" }
}

/// Parses the TOML subset used by plugin manifests: comments, `[table]` and
/// `[[array]]` headers with dotted keys, bare or quoted keys, basic and
/// literal strings, integers, booleans, arrays, and inline tables.
public struct CmuxPluginTOMLParser {
    private static let maximumNestingDepth = 32

    public init() {}

    public func parse(_ text: String) throws -> [String: CmuxPluginTOMLValue] {
        var scanner = Scanner(scalars: Array(text.unicodeScalars))
        let root = Node()
        var current = root
        while true {
            scanner.skipBlankLinesAndComments()
            guard let scalar = scanner.peek() else { break }
            if scalar == "[" {
                current = try parseHeader(&scanner, root: root)
            } else {
                let path = try parseKey(&scanner)
                scanner.skipSpaces()
                try scanner.expect("=")
                scanner.skipSpaces()
                let value = try parseValue(&scanner)
                try assign(value, path: path, in: current, scanner: scanner)
            }
            try scanner.expectLineEnd()
        }
        return root.dictionary()
    }

    private final class Node {
        enum Entry {
            case value(CmuxPluginTOMLValue)
            case table(Node)
            case tableArray([Node])
        }

        var entries: [String: Entry] = [:]
        /// True when a `[header]` created this table explicitly.
        var isExplicit = false

        func dictionary() -> [String: CmuxPluginTOMLValue] {
            entries.mapValues { entry in
                switch entry {
                case .value(let value):
                    return value
                case .table(let node):
                    return .table(node.dictionary())
                case .tableArray(let nodes):
                    return .array(nodes.map { .table($0.dictionary()) })
                }
            }
        }
    }

    private func parseHeader(_ scanner: inout Scanner, root: Node) throws -> Node {
        scanner.advance()
        let isArray = scanner.peek() == "["
        if isArray { scanner.advance() }
        scanner.skipSpaces()
        let path = try parseKey(&scanner)
        scanner.skipSpaces()
        try scanner.expect("]")
        if isArray { try scanner.expect("]") }

        var node = root
        for key in path.dropLast() {
            node = try descend(into: node, key: key, scanner: scanner)
        }
        let last = path[path.count - 1]
        if isArray {
            let element = Node()
            element.isExplicit = true
            switch node.entries[last] {
            case nil:
                node.entries[last] = .tableArray([element])
            case .tableArray(var nodes)?:
                nodes.append(element)
                node.entries[last] = .tableArray(nodes)
            default:
                throw scanner.error("'\(last)' is already defined and is not an array of tables")
            }
            return element
        }
        switch node.entries[last] {
        case nil:
            let table = Node()
            table.isExplicit = true
            node.entries[last] = .table(table)
            return table
        case .table(let table)? where !table.isExplicit:
            table.isExplicit = true
            return table
        default:
            throw scanner.error("table '\(path.joined(separator: "."))' is defined more than once")
        }
    }

    /// Walks one dotted-key segment, creating an implicit table when needed.
    /// An array of tables resolves to its most recent element, as in TOML.
    private func descend(into node: Node, key: String, scanner: Scanner) throws -> Node {
        switch node.entries[key] {
        case nil:
            let table = Node()
            node.entries[key] = .table(table)
            return table
        case .table(let table)?:
            return table
        case .tableArray(let nodes)?:
            return nodes[nodes.count - 1]
        case .value?:
            throw scanner.error("'\(key)' is already defined as a value")
        }
    }

    private func assign(
        _ value: CmuxPluginTOMLValue,
        path: [String],
        in table: Node,
        scanner: Scanner
    ) throws {
        var node = table
        for key in path.dropLast() {
            node = try descend(into: node, key: key, scanner: scanner)
        }
        let last = path[path.count - 1]
        guard node.entries[last] == nil else {
            throw scanner.error("key '\(path.joined(separator: "."))' is defined more than once")
        }
        node.entries[last] = .value(value)
    }

    private func parseKey(_ scanner: inout Scanner) throws -> [String] {
        var parts: [String] = []
        while true {
            scanner.skipSpaces()
            switch scanner.peek() {
            case "\"":
                parts.append(try parseBasicString(&scanner))
            case "'":
                parts.append(try parseLiteralString(&scanner))
            default:
                var bare = ""
                while let scalar = scanner.peek(), Self.isBareKeyScalar(scalar) {
                    bare.unicodeScalars.append(scalar)
                    scanner.advance()
                }
                guard !bare.isEmpty else { throw scanner.error("expected a key") }
                parts.append(bare)
            }
            scanner.skipSpaces()
            guard scanner.peek() == "." else { return parts }
            scanner.advance()
        }
    }

    private func parseValue(_ scanner: inout Scanner, depth: Int = 0) throws -> CmuxPluginTOMLValue {
        guard depth <= Self.maximumNestingDepth else {
            throw scanner.error("nested value exceeds maximum depth")
        }
        guard let scalar = scanner.peek() else { throw scanner.error("expected a value") }
        switch scalar {
        case "\"":
            if scanner.hasPrefix("\"\"\"") { throw scanner.error("multi-line strings are not supported") }
            return .string(try parseBasicString(&scanner))
        case "'":
            if scanner.hasPrefix("'''") { throw scanner.error("multi-line strings are not supported") }
            return .string(try parseLiteralString(&scanner))
        case "[":
            return try parseArray(&scanner, depth: depth + 1)
        case "{":
            return try parseInlineTable(&scanner, depth: depth + 1)
        default:
            var token = ""
            while let next = scanner.peek(), Self.isBareKeyScalar(next) || next == "+" || next == "." || next == ":" {
                token.unicodeScalars.append(next)
                scanner.advance()
            }
            if token == "true" { return .bool(true) }
            if token == "false" { return .bool(false) }
            let signless = token.first.map { $0 == "+" || $0 == "-" ? String(token.dropFirst()) : token } ?? ""
            let validUnderscores = !signless.isEmpty
                && !signless.hasPrefix("_")
                && !signless.hasSuffix("_")
                && !signless.contains("__")
            let digits = signless.replacingOccurrences(of: "_", with: "")
            let validLeadingZero = digits.count <= 1 || digits.first != "0"
            if validUnderscores,
               validLeadingZero,
               !digits.isEmpty,
               digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
               let integer = Int((token.first == "+" || token.first == "-") ? String(token.prefix(1)) + digits : digits) {
                return .integer(integer)
            }
            throw scanner.error(token.isEmpty ? "expected a value" : "unsupported value '\(token)'")
        }
    }

    private func parseArray(_ scanner: inout Scanner, depth: Int) throws -> CmuxPluginTOMLValue {
        scanner.advance()
        var values: [CmuxPluginTOMLValue] = []
        while true {
            scanner.skipBlankLinesAndComments()
            if scanner.peek() == "]" {
                scanner.advance()
                return .array(values)
            }
            values.append(try parseValue(&scanner, depth: depth))
            scanner.skipBlankLinesAndComments()
            if scanner.peek() == "," {
                scanner.advance()
            } else if scanner.peek() != "]" {
                throw scanner.error("expected ',' or ']' in array")
            }
        }
    }

    private func parseInlineTable(_ scanner: inout Scanner, depth: Int) throws -> CmuxPluginTOMLValue {
        scanner.advance()
        let node = Node()
        scanner.skipSpaces()
        if scanner.peek() == "}" {
            scanner.advance()
            return .table([:])
        }
        while true {
            let path = try parseKey(&scanner)
            scanner.skipSpaces()
            try scanner.expect("=")
            scanner.skipSpaces()
            try assign(try parseValue(&scanner, depth: depth), path: path, in: node, scanner: scanner)
            scanner.skipSpaces()
            if scanner.peek() == "}" {
                scanner.advance()
                return .table(node.dictionary())
            }
            try scanner.expect(",")
        }
    }

    private func parseBasicString(_ scanner: inout Scanner) throws -> String {
        scanner.advance()
        var result = String.UnicodeScalarView()
        while let scalar = scanner.peek() {
            scanner.advance()
            switch scalar {
            case "\"":
                return String(result)
            case "\n":
                throw scanner.error("unterminated string")
            case "\\":
                guard let escape = scanner.peek() else { throw scanner.error("unterminated string") }
                scanner.advance()
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u", "U":
                    let length = escape == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0..<length {
                        guard let digit = scanner.peek() else { throw scanner.error("invalid unicode escape") }
                        hex.unicodeScalars.append(digit)
                        scanner.advance()
                    }
                    guard let value = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(value) else {
                        throw scanner.error("invalid unicode escape")
                    }
                    result.append(decoded)
                default:
                    throw scanner.error("invalid escape '\\\(escape)'")
                }
            default:
                result.append(scalar)
            }
        }
        throw scanner.error("unterminated string")
    }

    private func parseLiteralString(_ scanner: inout Scanner) throws -> String {
        scanner.advance()
        var result = String.UnicodeScalarView()
        while let scalar = scanner.peek() {
            scanner.advance()
            if scalar == "'" { return String(result) }
            if scalar == "\n" { break }
            result.append(scalar)
        }
        throw scanner.error("unterminated string")
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-":
            return true
        default:
            return false
        }
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1

        func peek() -> Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        func hasPrefix(_ prefix: String) -> Bool {
            let prefixScalars = Array(prefix.unicodeScalars)
            guard index + prefixScalars.count <= scalars.count else { return false }
            return Array(scalars[index..<(index + prefixScalars.count)]) == prefixScalars
        }

        mutating func advance() {
            if peek() == "\n" { line += 1 }
            index += 1
        }

        mutating func skipSpaces() {
            while let scalar = peek(), scalar == " " || scalar == "\t" { advance() }
        }

        mutating func skipComment() {
            guard peek() == "#" else { return }
            while let scalar = peek(), scalar != "\n" { advance() }
        }

        mutating func skipBlankLinesAndComments() {
            while true {
                skipSpaces()
                skipComment()
                switch peek() {
                case "\n", "\r":
                    advance()
                default:
                    return
                }
            }
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard peek() == scalar else { throw error("expected '\(scalar)'") }
            advance()
        }

        mutating func expectLineEnd() throws {
            skipSpaces()
            skipComment()
            if peek() == "\r" { advance() }
            switch peek() {
            case nil:
                return
            case "\n":
                advance()
            default:
                throw error("unexpected text after value")
            }
        }

        func error(_ message: String) -> CmuxPluginTOMLError {
            CmuxPluginTOMLError(line: line, message: message)
        }
    }
}
