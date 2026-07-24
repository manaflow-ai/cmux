import Foundation

struct HTMLPlainTextParser: Sendable {
    private static let hiddenBlockTags: Set<String> = [
        "noscript",
        "script",
        "style",
        "template",
    ]

    private static let blockBoundaryTags: Set<String> = [
        "address",
        "article",
        "aside",
        "blockquote",
        "dd",
        "div",
        "dl",
        "dt",
        "figcaption",
        "figure",
        "footer",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "hr",
        "li",
        "main",
        "nav",
        "ol",
        "p",
        "pre",
        "section",
        "table",
        "tbody",
        "td",
        "tfoot",
        "th",
        "thead",
        "tr",
        "ul",
    ]

    private static let namedEntities: [String: String] = [
        "amp": "&",
        "apos": "'",
        "bull": "•",
        "copy": "©",
        "emsp": " ",
        "ensp": " ",
        "gt": ">",
        "hellip": "…",
        "laquo": "«",
        "larr": "←",
        "lt": "<",
        "mdash": "—",
        "middot": "·",
        "nbsp": " ",
        "ndash": "–",
        "quot": "\"",
        "raquo": "»",
        "reg": "®",
        "rarr": "→",
        "thinsp": " ",
        "trade": "™",
    ]

    func plainText(from html: String) -> String? {
        var output = ""
        output.reserveCapacity(min(html.count, 16_384))
        var hiddenTag: String?
        var index = html.startIndex

        while index < html.endIndex {
            if html[index] != "<" {
                let textEnd =
                    html[index...].firstIndex(of: "<")
                    ?? html.endIndex
                if hiddenTag == nil {
                    appendVisibleText(
                        String(html[index..<textEnd]),
                        to: &output
                    )
                }
                index = textEnd
                continue
            }

            if html[index...].hasPrefix("<!--") {
                guard let commentEnd = html.range(
                    of: "-->",
                    range: index..<html.endIndex
                )?.upperBound else {
                    break
                }
                index = commentEnd
                continue
            }

            guard let tagEnd = endOfTag(in: html, startingAt: index) else {
                if hiddenTag == nil {
                    output.append("<")
                }
                index = html.index(after: index)
                continue
            }

            let tagStart = html.index(after: index)
            let tag = parsedTag(String(html[tagStart..<tagEnd]))
            index = html.index(after: tagEnd)
            guard let tag else { continue }

            if let currentHiddenTag = hiddenTag {
                if tag.isClosing, tag.name == currentHiddenTag {
                    hiddenTag = nil
                }
                continue
            }

            if Self.hiddenBlockTags.contains(tag.name) {
                if !tag.isClosing, !tag.isSelfClosing {
                    hiddenTag = tag.name
                }
                continue
            }

            if tag.name == "br"
                || Self.blockBoundaryTags.contains(tag.name) {
                appendBlockBoundary(to: &output)
            }
        }

        let normalized = normalize(output)
        return normalized.isEmpty ? nil : normalized
    }

    private struct ParsedTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private func endOfTag(
        in html: String,
        startingAt openingBracket: String.Index
    ) -> String.Index? {
        var index = html.index(after: openingBracket)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private func parsedTag(_ rawTag: String) -> ParsedTag? {
        var tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty,
              tag.first != "!",
              tag.first != "?" else {
            return nil
        }

        let isClosing = tag.first == "/"
        if isClosing {
            tag.removeFirst()
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isSelfClosing = tag.last == "/"
        let name = tag.prefix { character in
            character.isLetter
                || character.isNumber
                || character == "-"
                || character == ":"
        }.lowercased()
        guard !name.isEmpty else { return nil }
        return ParsedTag(
            name: name,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing
        )
    }

    private func appendVisibleText(
        _ htmlText: String,
        to output: inout String
    ) {
        for character in decodeEntities(in: htmlText) {
            output.append(character.isWhitespace ? " " : character)
        }
    }

    private func appendBlockBoundary(to output: inout String) {
        guard !output.isEmpty, output.last != "\n" else { return }
        while output.last == " " {
            output.removeLast()
        }
        if !output.isEmpty {
            output.append("\n")
        }
    }

    private func decodeEntities(in text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = entitySemicolon(
                    in: text,
                    after: index
                  ) else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            let bodyStart = text.index(after: index)
            let body = String(text[bodyStart..<semicolon])
            if let decoded = decodedEntity(body) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private func entitySemicolon(
        in text: String,
        after ampersand: String.Index
    ) -> String.Index? {
        var index = text.index(after: ampersand)
        for _ in 0..<32 where index < text.endIndex {
            let character = text[index]
            if character == ";" {
                return index
            }
            if character == "&" || character == "<" || character.isWhitespace {
                return nil
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func decodedEntity(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return unicodeScalarString(
                String(body.dropFirst(2)),
                radix: 16
            )
        }
        if body.hasPrefix("#") {
            return unicodeScalarString(
                String(body.dropFirst()),
                radix: 10
            )
        }
        return Self.namedEntities[body.lowercased()]
    }

    private func unicodeScalarString(
        _ digits: String,
        radix: Int
    ) -> String? {
        guard let value = UInt32(digits, radix: radix),
              let scalar = UnicodeScalar(value) else {
            return nil
        }
        return String(scalar)
    }

    private func normalize(_ text: String) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(text.count)
        var pendingSpace = false

        for character in text {
            if character == "\n" {
                pendingSpace = false
                while characters.last == " " {
                    characters.removeLast()
                }
                if !characters.isEmpty, characters.last != "\n" {
                    characters.append("\n")
                }
            } else if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace,
                   !characters.isEmpty,
                   characters.last != "\n" {
                    characters.append(" ")
                }
                pendingSpace = false
                characters.append(character)
            }
        }

        while characters.last?.isWhitespace == true {
            characters.removeLast()
        }
        return String(characters)
    }
}
