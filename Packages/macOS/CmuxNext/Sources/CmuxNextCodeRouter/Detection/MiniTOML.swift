import Foundation

/// The part of TOML Codex's provider settings use: `[table.headers]`,
/// `key = value` with dotted and quoted keys, string and boolean values,
/// and inline tables (`key = { a = "x", b = { c = true } }`, read into the
/// same paths a `[key]` table gives, as Codex's own reader does). Anything
/// else (arrays, numbers, multi-line strings) is kept only as present.
/// Never throws: a line it cannot read is skipped.
struct MiniTOML {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case other
    }

    private(set) var values: [[String]: Value] = [:]
    private(set) var tables: Set<[String]> = [[]]

    init(_ text: String) {
        var table: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") { table = ["\u{0}array"]; continue }
            if line.hasPrefix("["), let close = Self.closingBracket(line) {
                table = Self.keyPath(String(line[line.index(after: line.startIndex)..<close]))
                for depth in 1...max(table.count, 1) { tables.insert(Array(table.prefix(depth))) }
                continue
            }
            var cursor = Cursor(line)
            guard let key = cursor.key() else { continue }
            assign(table + key, below: table.count, &cursor)
        }
    }

    func string(_ path: [String]) -> String? {
        if case .string(let text) = values[path] { return text }
        return nil
    }

    func bool(_ path: [String]) -> Bool? {
        if case .bool(let flag) = values[path] { return flag }
        return nil
    }

    func has(_ path: [String]) -> Bool { values[path] != nil }

    func hasTable(_ path: [String]) -> Bool { tables.contains(path) }

    /// `a.b."c.d"` -> `["a", "b", "c.d"]`.
    static func keyPath(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.contains(where: \.isEmpty) ? [] : parts
    }

    /// The value at the cursor goes to `path`; the dotted key's parents
    /// (below the table it was written in, at depth `base`) become tables.
    /// An inline table becomes a table and its keys go below it.
    private mutating func assign(_ path: [String], below base: Int, _ cursor: inout Cursor) {
        for depth in base..<path.count { tables.insert(Array(path.prefix(depth))) }
        cursor.skipSpaces()
        guard cursor.peek == "{" else {
            values[path] = cursor.scalar()
            return
        }
        cursor.advance()
        tables.insert(path)
        values[path] = .other
        // Every pass moves the cursor forward or returns; the line's end ends it.
        cursor.skipSpaces()
        while let character = cursor.peek {
            switch character {
            case "}": cursor.advance(); return
            case ",": cursor.advance()
            default:
                guard let key = cursor.key() else { return }
                assign(path + key, below: path.count, &cursor)
            }
            cursor.skipSpaces()
        }
    }

    private static func closingBracket(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote { if character == open { quote = nil } } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                return index
            }
        }
        return nil
    }

    /// Reads one line left to right: keys, scalars, and the brackets of an
    /// inline table or array.
    private struct Cursor {
        let characters: [Character]
        var index = 0

        init(_ text: String) { characters = Array(text) }

        var peek: Character? { index < characters.count ? characters[index] : nil }

        mutating func advance() { index += 1 }

        mutating func skipSpaces() {
            while let character = peek, character == " " || character == "\t" { index += 1 }
        }

        /// A key up to its unquoted `=`, past which the cursor moves; nil
        /// when the text holds no key.
        mutating func key() -> [String]? {
            var text = "", quote: Character?
            while let character = peek {
                index += 1
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "=" {
                    let path = MiniTOML.keyPath(text)
                    return path.isEmpty ? nil : path
                } else if character == "," || character == "{" || character == "}" || character == "#" {
                    return nil
                }
                text.append(character)
            }
            return nil
        }

        /// A string, a boolean, or anything else as present. The cursor
        /// stops after it, at the `,` or `}` that may follow.
        mutating func scalar() -> Value {
            guard let open = peek else { return .other }
            if open == "\"" || open == "'" {
                if characters[index...].starts(with: [open, open, open]) {
                    index = characters.count
                    return .other
                }
                index += 1
                var result = "", escaped = false
                while let character = peek {
                    index += 1
                    if escaped { result.append(character); escaped = false; continue }
                    if character == "\\" && open == "\"" { escaped = true; continue }
                    if character == open { return .string(result) }
                    result.append(character)
                }
                return .other
            }
            if open == "[" {
                skipArray()
                return .other
            }
            var bare = ""
            while let character = peek, character != ",", character != "}", character != "#" {
                bare.append(character)
                index += 1
            }
            switch bare.trimmingCharacters(in: .whitespaces) {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return .other
            }
        }

        /// Past a `[...]` array, nested brackets and quoted text included.
        mutating func skipArray() {
            var depth = 0, quote: Character?, escaped = false
            while let character = peek {
                index += 1
                if let open = quote {
                    if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "[" {
                    depth += 1
                } else if character == "]" {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
        }
    }
}
