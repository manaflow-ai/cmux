import Foundation

/// Extracts visible text with Foundation's non-AppKit HTML parser.
///
/// `NSAttributedString`'s HTML importer can synchronously hand work back to the
/// main thread. `XMLDocument` stays on the caller's executor, repairs malformed
/// markup, and decodes standard HTML entities without loading external content.
struct HTMLPlainTextParser: Sendable {
    private static let hiddenBlockTags: Set<String> = [
        "head",
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
        "body",
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

    func plainText(from html: String) -> String? {
        guard let document = try? XMLDocument(
            xmlString: html,
            options: [
                .documentTidyHTML,
                .nodeLoadExternalEntitiesNever,
            ]
        ), let root = document.rootElement() else {
            return nil
        }

        var output = ""
        output.reserveCapacity(min(html.count, 16_384))
        appendVisibleText(from: root, to: &output)

        let normalized = normalize(output)
        return normalized.isEmpty ? nil : normalized
    }

    private func appendVisibleText(
        from node: XMLNode,
        to output: inout String
    ) {
        switch node.kind {
        case .text:
            guard let text = node.stringValue else { return }
            appendText(text, to: &output)
        case .element:
            let name = node.name?.lowercased() ?? ""
            guard !Self.hiddenBlockTags.contains(name) else { return }

            if name == "br" {
                appendBlockBoundary(to: &output)
                return
            }

            let isBlock = Self.blockBoundaryTags.contains(name)
            if isBlock {
                appendBlockBoundary(to: &output)
            }
            for child in node.children ?? [] {
                appendVisibleText(from: child, to: &output)
            }
            if isBlock {
                appendBlockBoundary(to: &output)
            }
        default:
            return
        }
    }

    private func appendText(
        _ text: String,
        to output: inout String
    ) {
        for character in text {
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
