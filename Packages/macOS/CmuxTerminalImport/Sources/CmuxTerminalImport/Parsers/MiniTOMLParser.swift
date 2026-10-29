import Foundation

/// A small TOML reader for terminal configs: tables, dotted keys, strings,
/// numbers, booleans, arrays and inline tables, flattened to dotted keys.
///
/// Arrays of tables (`[[keyboard.bindings]]`) are skipped; nothing imported lives there.
struct MiniTOMLParser {
    func parse(_ text: String) -> [String: ConfigValue] {
        var result: [String: ConfigValue] = [:]
        var scanner = CharacterScanner(text)
        var table: [String] = []
        var skippingArrayTable = false

        while !scanner.isAtEnd {
            scanner.skipWhitespaceAndNewlines()
            guard let char = scanner.peek else { break }
            if char == "#" {
                scanner.skipLine()
                continue
            }
            if char == "[" {
                scanner.advance()
                if scanner.peek == "[" {
                    skippingArrayTable = true
                    scanner.skipLine()
                    continue
                }
                skippingArrayTable = false
                table = parseKey(&scanner, terminator: "]")
                scanner.advance()
                scanner.skipLine()
                continue
            }
            let key = parseKey(&scanner, terminator: "=")
            guard scanner.peek == "=" else {
                scanner.skipLine()
                continue
            }
            scanner.advance()
            scanner.skipSpaces()
            let value = parseValue(&scanner)
            if !skippingArrayTable, !key.isEmpty {
                store(value, at: table + key, into: &result)
            }
            scanner.skipLine()
        }
        return result
    }

    private indirect enum Parsed {
        case value(ConfigValue)
        case table([(key: [String], value: Parsed)])
    }

    private func store(_ parsed: Parsed?, at path: [String], into result: inout [String: ConfigValue]) {
        switch parsed {
        case .value(let value)?:
            result[path.joined(separator: ".")] = value
        case .table(let entries)?:
            for entry in entries {
                store(entry.value, at: path + entry.key, into: &result)
            }
        case nil:
            break
        }
    }

    private func parseKey(_ scanner: inout CharacterScanner, terminator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        while let char = scanner.peek, char != terminator, char != "\n" {
            switch char {
            case "\"", "'":
                current += scanner.readQuoted() ?? ""
            case ".":
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                scanner.advance()
            default:
                current.append(char)
                scanner.advance()
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !parts.isEmpty { parts.append(last) }
        return parts
    }

    private func parseValue(_ scanner: inout CharacterScanner) -> Parsed? {
        guard let char = scanner.peek else { return nil }
        switch char {
        case "\"", "'":
            return scanner.readQuoted().map { .value(.string($0)) }
        case "[":
            scanner.advance()
            var items: [ConfigValue] = []
            while true {
                scanner.skipWhitespaceNewlinesAndComments()
                guard let next = scanner.peek else { break }
                if next == "]" {
                    scanner.advance()
                    break
                }
                if next == "," {
                    scanner.advance()
                    continue
                }
                if case .value(let value)? = parseValue(&scanner) {
                    items.append(value)
                } else {
                    scanner.advance()
                }
            }
            return .value(.list(items))
        case "{":
            scanner.advance()
            var entries: [(key: [String], value: Parsed)] = []
            while true {
                scanner.skipSpaces()
                guard let next = scanner.peek, next != "\n" else { break }
                if next == "}" {
                    scanner.advance()
                    break
                }
                if next == "," {
                    scanner.advance()
                    continue
                }
                let key = parseKey(&scanner, terminator: "=")
                guard scanner.peek == "=" else { break }
                scanner.advance()
                scanner.skipSpaces()
                if let value = parseValue(&scanner) {
                    entries.append((key, value))
                }
            }
            return .table(entries)
        default:
            var word = ""
            while let next = scanner.peek, !",]}\n#".contains(next) {
                word.append(next)
                scanner.advance()
            }
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            // TOML allows `10_000`; strip digit separators only when the result is a number.
            let digits = trimmed.replacingOccurrences(of: "_", with: "")
            if let number = ConfigValue.decimal(digits) { return .value(.number(number)) }
            return trimmed.isEmpty ? nil : .value(.bare(trimmed))
        }
    }
}
