import Foundation

/// A small YAML reader for the legacy `alacritty.yml` and Warp theme files:
/// nested block mappings, scalars, and lists of scalars, flattened to dotted keys.
///
/// Anchors, multi-document streams and block scalars are not supported; those
/// keys are simply not read.
struct MiniYAMLParser {
    func parse(_ text: String) -> [String: ConfigValue] {
        var result: [String: ConfigValue] = [:]
        var stack: [(indent: Int, key: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = Self.strippingComment(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            let content = line.trimmingCharacters(in: .whitespaces)

            if content.hasPrefix("- ") || content == "-" {
                // A list item belongs to the nearest open key with a smaller or equal indent.
                while let last = stack.last, last.indent > indent { stack.removeLast() }
                let path = stack.map(\.key).joined(separator: ".")
                let item = Self.scalar(String(content.dropFirst()).trimmingCharacters(in: .whitespaces))
                if case .list(let items)? = result[path] {
                    result[path] = .list(items + [item])
                } else {
                    result[path] = .list([item])
                }
                continue
            }

            guard let colon = Self.keySeparator(in: content) else { continue }
            let key = Self.unquote(String(content[..<colon]).trimmingCharacters(in: .whitespaces))
            let value = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty {
                stack.append((indent, key))
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                let items = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { Self.scalar(String($0).trimmingCharacters(in: .whitespaces)) }
                result[path] = .list(items)
            } else {
                result[path] = Self.scalar(value)
            }
        }
        return result
    }

    private static func keySeparator(in content: String) -> String.Index? {
        var quote: Character?
        for index in content.indices {
            let char = content[index]
            if let open = quote {
                if char == open { quote = nil }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
            } else if char == ":" {
                let next = content.index(after: index)
                if next == content.endIndex || content[next] == " " { return index }
            }
        }
        return nil
    }

    private static func strippingComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for index in line.indices {
            let char = line[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#", previous == " " || previous == "\t" {
                return String(line[..<index])
            }
            previous = char
        }
        return line
    }

    private static func unquote(_ text: String) -> String {
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func scalar(_ text: String) -> ConfigValue {
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return .string(String(text.dropFirst().dropLast()))
        }
        return .bare(text)
    }
}
