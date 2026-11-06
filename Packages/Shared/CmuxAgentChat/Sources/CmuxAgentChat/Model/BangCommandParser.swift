import Foundation

/// Finds suggested bang commands in original agent messages without screen-row reconstruction.
public enum BangCommandParser {
    /// Returns complete commands while preserving paths, quoting and real script newlines.
    /// Ambiguous shell constructs are withheld rather than guessed into executable text.
    public static func commands(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var seen: Set<String> = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let inline = captures(#"\u0060(![ \t]+[^\u0060\r\n]+)\u0060"#, in: line)
            if !inline.isEmpty {
                for candidate in inline {
                    var end = 0
                    if let command = complete(candidate, lines: [], index: &end), seen.insert(command).inserted {
                        result.append(command)
                    }
                }
                continue
            }
            guard let candidate = captures(#"^\s*(?:[-*+]\s+)?(?:[^!\n]*:\s+)?(![ \t]+\S.*)$"#, in: line).first else { continue }
            guard let command = complete(candidate, lines: lines, index: &index) else { break }
            if seen.insert(command).inserted { result.append(command) }
        }
        return result
    }

    private static func complete(_ first: String, lines: [String], index: inout Int) -> String? {
        var command = first
        var line = first
        var quote: Character?
        while true {
            var documents: [(delimiter: String, stripTabs: Bool)] = []
            guard let continues = scan(line, quote: &quote, documents: &documents) else { return nil }
            if !documents.isEmpty {
                guard !continues else { return nil }
                for document in documents {
                    var closed = false
                    while index < lines.count {
                        let body = lines[index]
                        index += 1
                        command += "\n" + body
                        let marker = document.stripTabs ? String(body.drop(while: { $0 == "\t" })) : body
                        if marker == document.delimiter { closed = true; break }
                    }
                    guard closed else { return nil }
                }
                return command
            }
            guard continues else { return command }
            guard index < lines.count else { return nil }
            line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix(String(repeating: "\u{60}", count: 3)),
                  !trimmed.hasPrefix("~~~") else { return nil }
            command += "\n" + line
        }
    }

    /// This deliberately recognizes only bounded quoting, escapes and here-docs.
    /// Shell groups, substitutions and block keywords need a full shell parser.
    private static func scan(
        _ line: String, quote: inout Character?,
        documents: inout [(delimiter: String, stripTabs: Bool)]
    ) -> Bool? {
        let characters = Array(line)
        var index = 0
        var word = ""
        var continuation = false
        var needsRedirectArgument = false
        let blocks: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac", "select", "function", "do", "done"]
        while index < characters.count {
            let character = characters[index]
            if quote == "'" {
                if character == "'" { quote = nil }
                index += 1
                continue
            }
            if character == "\\" {
                if index + 1 == characters.count {
                    continuation = true
                    index += 1
                } else {
                    word += String(characters[index + 1])
                    needsRedirectArgument = false
                    index += 2
                }
                continue
            }
            if quote == "\"" {
                if character == "\"" { quote = nil }
                if character == "\u{60}" || (character == "$" && index + 1 < characters.count && characters[index + 1] == "(") { return nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                guard word != "$", !blocks.contains(word) else { return nil }
                word = ""
                quote = character
                needsRedirectArgument = false
                continuation = false
                index += 1
                continue
            }
            if character == "#", word.isEmpty { break }
            if character == "\u{60}" || "(){}".contains(character) { return nil }
            if character == "<", index + 1 < characters.count, characters[index + 1] == "<" {
                guard !blocks.contains(word) else { return nil }
                index += 2
                if index < characters.count, characters[index] == "<" {
                    index += 1
                    needsRedirectArgument = true
                    continue
                }
                let stripTabs = index < characters.count && characters[index] == "-"
                if stripTabs { index += 1 }
                while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
                guard index < characters.count else { return nil }
                let delimiterQuote: Character? = characters[index] == "'" || characters[index] == "\"" ? characters[index] : nil
                if delimiterQuote != nil { index += 1 }
                var delimiter = ""
                while index < characters.count {
                    let value = characters[index]
                    if let delimiterQuote {
                        if value == delimiterQuote { break }
                        guard value != "\\" else { return nil }
                    } else if !value.isLetter && !value.isNumber && value != "_" && value != "-" {
                        break
                    }
                    delimiter.append(value)
                    index += 1
                }
                guard !delimiter.isEmpty else { return nil }
                if delimiterQuote != nil {
                    guard index < characters.count else { return nil }
                    index += 1
                }
                if index < characters.count {
                    let next = characters[index]
                    guard next.isWhitespace || ";|&<>".contains(next) else { return nil }
                }
                documents.append((delimiter, stripTabs))
                word = ""
                continuation = false
                continue
            }
            if character.isWhitespace || ";|&<>".contains(character) {
                guard !blocks.contains(word) else { return nil }
                word = ""
                if "|&".contains(character) {
                    let doubled = index + 1 < characters.count && characters[index + 1] == character
                    continuation = character == "|" || doubled
                    if doubled { index += 1 }
                } else if "<>".contains(character) {
                    needsRedirectArgument = true
                } else if character == ";" {
                    continuation = false
                }
            } else {
                word.append(character)
                needsRedirectArgument = false
                continuation = false
            }
            index += 1
        }
        guard !blocks.contains(word), !needsRedirectArgument else { return nil }
        return quote != nil || continuation
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range(at: 1))
        }
    }
}
