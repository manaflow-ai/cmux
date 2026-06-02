import Foundation

/// Turns source text into a list of top-level `LispValue` forms.
///
/// Syntax (Scheme-ish):
///   - lists `(...)`, scalars, `:keywords`, `'quote` sugar
///   - `;` line comments
///   - strings with `\n \t \" \\` escapes
///   - `true`, `false`, `nil` literals
///   - integers and doubles, including negatives
public struct Reader {
    public init() {}

    public func read(_ source: String) throws -> [LispValue] {
        var tokenizer = Tokenizer(source)
        let tokens = try tokenizer.tokenize()
        var parser = Parser(tokens)
        return try parser.parseAll()
    }
}

// MARK: - Tokens

private enum Token: Equatable {
    case lparen(line: Int)
    case rparen(line: Int)
    case quote(line: Int)
    case atom(String, line: Int)
    case string(String, line: Int)

    var line: Int {
        switch self {
        case let .lparen(l), let .rparen(l), let .quote(l): return l
        case let .atom(_, l), let .string(_, l): return l
        }
    }
}

private struct Tokenizer {
    private let chars: [Character]
    private var index = 0
    private var line = 1

    init(_ source: String) { chars = Array(source) }

    private var current: Character? { index < chars.count ? chars[index] : nil }

    private mutating func advance() -> Character {
        let c = chars[index]
        index += 1
        if c == "\n" { line += 1 }
        return c
    }

    mutating func tokenize() throws -> [Token] {
        var tokens: [Token] = []
        while let c = current {
            if c == "\n" || c == " " || c == "\t" || c == "\r" || c == "," {
                _ = advance()
            } else if c == ";" {
                while let n = current, n != "\n" { _ = advance() }
            } else if c == "(" || c == "[" {
                let l = line; _ = advance(); tokens.append(.lparen(line: l))
            } else if c == ")" || c == "]" {
                let l = line; _ = advance(); tokens.append(.rparen(line: l))
            } else if c == "'" {
                let l = line; _ = advance(); tokens.append(.quote(line: l))
            } else if c == "\"" {
                tokens.append(try readString())
            } else {
                tokens.append(readAtom())
            }
        }
        return tokens
    }

    private mutating func readString() throws -> Token {
        let startLine = line
        _ = advance() // opening quote
        var out = ""
        while let c = current {
            if c == "\"" {
                _ = advance()
                return .string(out, line: startLine)
            } else if c == "\\" {
                _ = advance()
                guard let esc = current else { break }
                _ = advance()
                switch esc {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(esc)
                }
            } else {
                out.append(advance())
            }
        }
        throw LispError.read(
            String(localized: "sidebarScript.error.unterminatedString",
                   defaultValue: "Unterminated string.", bundle: .module),
            line: startLine
        )
    }

    private mutating func readAtom() -> Token {
        let startLine = line
        var out = ""
        while let c = current {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == ","
                || c == "(" || c == ")" || c == "[" || c == "]"
                || c == "'" || c == "\"" || c == ";" {
                break
            }
            out.append(advance())
        }
        return .atom(out, line: startLine)
    }
}

// MARK: - Parser

private struct Parser {
    private let tokens: [Token]
    private var index = 0

    init(_ tokens: [Token]) { self.tokens = tokens }

    private var current: Token? { index < tokens.count ? tokens[index] : nil }

    mutating func parseAll() throws -> [LispValue] {
        var forms: [LispValue] = []
        while current != nil {
            forms.append(try parseForm())
        }
        return forms
    }

    private mutating func parseForm() throws -> LispValue {
        guard let token = current else {
            throw LispError.read(String(
                localized: "sidebarScript.error.unexpectedEnd",
                defaultValue: "Unexpected end of input.", bundle: .module))
        }
        switch token {
        case .lparen:
            index += 1
            var items: [LispValue] = []
            while let t = current, !isRParen(t) {
                items.append(try parseForm())
            }
            guard let close = current, isRParen(close) else {
                throw LispError.read(String(
                    localized: "sidebarScript.error.unclosedList",
                    defaultValue: "Missing ')'.", bundle: .module), line: token.line)
            }
            index += 1
            return .list(items)
        case .rparen(let l):
            throw LispError.read(String(
                localized: "sidebarScript.error.unexpectedParen",
                defaultValue: "Unexpected ')'.", bundle: .module), line: l)
        case .quote:
            index += 1
            let quoted = try parseForm()
            return .list([.symbol("quote"), quoted])
        case let .string(s, _):
            index += 1
            return .string(s)
        case let .atom(a, line):
            index += 1
            return atomValue(a, line: line)
        }
    }

    private func isRParen(_ t: Token) -> Bool {
        if case .rparen = t { return true }
        return false
    }

    private func atomValue(_ atom: String, line: Int) -> LispValue {
        if atom == "true" { return .bool(true) }
        if atom == "false" { return .bool(false) }
        if atom == "nil" { return .null }
        if atom.hasPrefix(":"), atom.count > 1 {
            return .keyword(String(atom.dropFirst()))
        }
        if let i = parseInt(atom) { return .int(i) }
        if let d = parseDouble(atom) { return .double(d) }
        return .symbol(atom)
    }

    private func parseInt(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        // Reject things like "1.0" or "1e3" here; those are doubles.
        guard s.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "+" }) else { return nil }
        return Int(s)
    }

    private func parseDouble(_ s: String) -> Double? {
        // Require at least one digit so bare symbols like "+" don't parse as 0.
        guard s.contains(where: { $0.isNumber }) else { return nil }
        let allowed = Set("0123456789.eE+-")
        guard s.allSatisfy({ allowed.contains($0) }) else { return nil }
        return Double(s)
    }
}
