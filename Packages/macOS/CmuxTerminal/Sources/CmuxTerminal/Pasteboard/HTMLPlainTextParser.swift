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

    private static let preformattedTags: Set<String> = [
        "listing",
        "pre",
        "textarea",
        "xmp",
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
        appendVisibleText(
            from: root,
            preservingWhitespace: false,
            to: &output
        )

        while output.last == "\n" {
            output.removeLast()
        }
        return output.isEmpty ? nil : output
    }

    private func appendVisibleText(
        from node: XMLNode,
        preservingWhitespace: Bool,
        to output: inout String
    ) {
        switch node.kind {
        case .text:
            guard let text = node.stringValue else { return }
            appendText(
                text,
                preservingWhitespace: preservingWhitespace,
                to: &output
            )
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
            let childPreservesWhitespace =
                preservingWhitespace || Self.preformattedTags.contains(name)
            for child in node.children ?? [] {
                appendVisibleText(
                    from: child,
                    preservingWhitespace: childPreservesWhitespace,
                    to: &output
                )
            }
            if isBlock {
                appendBlockBoundary(
                    to: &output,
                    trimmingTrailingSpaces: !childPreservesWhitespace
                )
            }
        default:
            return
        }
    }

    private func appendText(
        _ text: String,
        preservingWhitespace: Bool,
        to output: inout String
    ) {
        if preservingWhitespace {
            output.append(contentsOf: text)
            return
        }

        for character in text {
            if character.isWhitespace {
                if !output.isEmpty,
                   output.last != " ",
                   output.last != "\n" {
                    output.append(" ")
                }
            } else {
                output.append(character)
            }
        }
    }

    private func appendBlockBoundary(
        to output: inout String,
        trimmingTrailingSpaces: Bool = true
    ) {
        guard !output.isEmpty, output.last != "\n" else { return }
        if trimmingTrailingSpaces {
            while output.last == " " {
                output.removeLast()
            }
        }
        if !output.isEmpty {
            output.append("\n")
        }
    }
}
