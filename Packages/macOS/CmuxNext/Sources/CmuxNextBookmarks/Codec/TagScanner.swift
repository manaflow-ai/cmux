import Foundation

/// A minimal HTML tag tokenizer for the Netscape bookmark format: tag names
/// lowercased (`/dl` for a closing tag), attribute names lowercased, values
/// with or without quotes. Comments and `<!DOCTYPE>` are skipped.
nonisolated struct TagScanner {
    nonisolated struct Tag {
        var name: String
        var attributes: [String: String]
    }

    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    /// The next tag, or nil at the end.
    mutating func nextTag() -> Tag? {
        while position < scalars.count {
            guard scalars[position] == "<" else {
                position += 1
                continue
            }
            if hasPrefix("<!--") {
                skip(past: "-->")
                continue
            }
            position += 1
            if position < scalars.count, scalars[position] == "!" || scalars[position] == "?" {
                skip(past: ">")
                continue
            }
            var name = ""
            if position < scalars.count, scalars[position] == "/" {
                name.unicodeScalars.append("/")
                position += 1
            }
            while position < scalars.count, Self.isNameCharacter(scalars[position]) {
                name.unicodeScalars.append(scalars[position])
                position += 1
            }
            guard name != "", name != "/" else { continue }
            let attributes = readAttributes()
            return Tag(name: name.lowercased(), attributes: attributes)
        }
        return nil
    }

    /// Raw text up to the closing `</name>` (or the next tag that opens a
    /// new entry, for files that forget to close), past the closing tag.
    mutating func text(until name: String) -> String {
        var text = ""
        while position < scalars.count {
            if scalars[position] == "<" {
                let closing = Array(("</" + name).unicodeScalars)
                if matches(closing, caseInsensitive: true) {
                    skip(past: ">")
                    return text
                }
                if matches(Array("<dt".unicodeScalars), caseInsensitive: true) || matches(Array("<dl".unicodeScalars), caseInsensitive: true)
                    || matches(Array("</dl".unicodeScalars), caseInsensitive: true) {
                    return text
                }
            }
            text.unicodeScalars.append(scalars[position])
            position += 1
        }
        return text
    }

    private mutating func readAttributes() -> [String: String] {
        var attributes: [String: String] = [:]
        while position < scalars.count {
            skipWhitespace()
            guard position < scalars.count else { break }
            if scalars[position] == ">" {
                position += 1
                break
            }
            if scalars[position] == "/" {
                position += 1
                continue
            }
            var name = ""
            while position < scalars.count, Self.isNameCharacter(scalars[position]) || scalars[position] == "-" {
                name.unicodeScalars.append(scalars[position])
                position += 1
            }
            if name.isEmpty {
                position += 1
                continue
            }
            skipWhitespace()
            var value = ""
            if position < scalars.count, scalars[position] == "=" {
                position += 1
                skipWhitespace()
                if position < scalars.count, scalars[position] == "\"" || scalars[position] == "'" {
                    let quote = scalars[position]
                    position += 1
                    while position < scalars.count, scalars[position] != quote {
                        value.unicodeScalars.append(scalars[position])
                        position += 1
                    }
                    position += 1
                } else {
                    while position < scalars.count, !Self.isSpace(scalars[position]), scalars[position] != ">" {
                        value.unicodeScalars.append(scalars[position])
                        position += 1
                    }
                }
            }
            attributes[name.lowercased()] = value
        }
        return attributes
    }

    private func hasPrefix(_ text: String) -> Bool { matches(Array(text.unicodeScalars), caseInsensitive: false) }

    private func matches(_ pattern: [Unicode.Scalar], caseInsensitive: Bool) -> Bool {
        guard position + pattern.count <= scalars.count else { return false }
        for (offset, expected) in pattern.enumerated() {
            let actual = scalars[position + offset]
            if caseInsensitive {
                guard Self.lower(actual) == Self.lower(expected) else { return false }
            } else if actual != expected {
                return false
            }
        }
        return true
    }

    private mutating func skip(past terminator: String) {
        let pattern = Array(terminator.unicodeScalars)
        while position < scalars.count, !matches(pattern, caseInsensitive: false) { position += 1 }
        position = min(position + pattern.count, scalars.count)
    }

    private mutating func skipWhitespace() {
        while position < scalars.count, Self.isSpace(scalars[position]) { position += 1 }
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    private static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_")
    }

    private static func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }
}
