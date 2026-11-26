/// Splits Lua source into names, strings, numbers and symbols, dropping comments.
struct LuaTokenizer {
    func tokens(in source: String) -> [LuaToken] {
        var scanner = CharacterScanner(source)
        var tokens: [LuaToken] = []
        var line = 1

        while let char = scanner.peek {
            if char == "\n" {
                line += 1
                scanner.advance()
                continue
            }
            if char.isWhitespace {
                scanner.advance()
                continue
            }
            if char == "-", scanner.peek(offset: 1) == "-" {
                scanner.advance(2)
                if let level = longBracketLevel(&scanner) {
                    line += skipLongBracket(&scanner, level: level).newlines
                } else {
                    while let next = scanner.peek, next != "\n" { scanner.advance() }
                }
                continue
            }
            if char == "[", let level = longBracketLevel(&scanner) {
                let body = skipLongBracket(&scanner, level: level)
                tokens.append(.init(kind: .string, text: body.text, line: line))
                line += body.newlines
                continue
            }
            if char == "\"" || char == "'" {
                tokens.append(.init(kind: .string, text: scanner.readQuoted() ?? "", line: line))
                continue
            }
            if char.isNumber || (char == "." && scanner.peek(offset: 1)?.isNumber == true) {
                var text = ""
                while let next = scanner.peek, next.isNumber || next.isLetter || next == "." {
                    text.append(next)
                    scanner.advance()
                }
                tokens.append(.init(kind: .number, text: text, line: line))
                continue
            }
            if char.isLetter || char == "_" {
                var text = ""
                while let next = scanner.peek, next.isLetter || next.isNumber || next == "_" {
                    text.append(next)
                    scanner.advance()
                }
                tokens.append(.init(kind: .name, text: text, line: line))
                continue
            }
            var symbol = String(char)
            scanner.advance()
            if let next = scanner.peek, ["..", "==", "~=", "<=", ">="].contains(symbol + String(next)) {
                symbol.append(next)
                scanner.advance()
            }
            tokens.append(.init(kind: .symbol, text: symbol, line: line))
        }
        return tokens
    }

    /// If the cursor is at `[[` or `[==[`, consumes the opener and returns its `=` count.
    private func longBracketLevel(_ scanner: inout CharacterScanner) -> Int? {
        guard scanner.peek == "[" else { return nil }
        var offset = 1
        while scanner.peek(offset: offset) == "=" { offset += 1 }
        guard scanner.peek(offset: offset) == "[" else { return nil }
        scanner.advance(offset + 1)
        return offset - 1
    }

    private func skipLongBracket(_ scanner: inout CharacterScanner, level: Int) -> (text: String, newlines: Int) {
        let closer = "]" + String(repeating: "=", count: level) + "]"
        var text = ""
        var newlines = 0
        while let char = scanner.peek {
            if char == "]" {
                var candidate = ""
                for offset in 0..<closer.count {
                    if let next = scanner.peek(offset: offset) { candidate.append(next) }
                }
                if candidate == closer {
                    scanner.advance(closer.count)
                    return (text, newlines)
                }
            }
            if char == "\n" { newlines += 1 }
            text.append(char)
            scanner.advance()
        }
        return (text, newlines)
    }
}
