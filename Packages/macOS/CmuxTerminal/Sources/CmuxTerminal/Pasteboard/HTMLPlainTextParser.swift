import Foundation

/// Extracts visible text with Foundation's non-AppKit HTML parser.
///
/// `NSAttributedString`'s HTML importer can synchronously hand work back to the
/// main thread. `XMLDocument` stays on the caller's executor, repairs malformed
/// markup, and decodes standard HTML entities without loading external content.
struct HTMLPlainTextParser: Sendable {
    /// Keeps synchronous drop inspection bounded before Foundation builds a DOM.
    static let maximumInputByteCount = 4 * 1024 * 1024
    private static let maximumOutputCharacterCount = 4 * 1024 * 1024

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
        guard html.utf8.count <= Self.maximumInputByteCount else {
            return nil
        }
        return plainText(
            fromBoundedData: Data(html.utf8),
            sourceLength: html.count
        )
    }

    func plainText(from data: Data) -> String? {
        guard data.count <= Self.maximumInputByteCount else {
            return nil
        }
        return plainText(fromBoundedData: data, sourceLength: data.count)
    }

    private func plainText(
        fromBoundedData data: Data,
        sourceLength: Int
    ) -> String? {
        let hiddenTemplateAttributeName =
            "data-cmux-hidden-template-\(UUID().uuidString.lowercased())"
        let normalizedData = HTMLFoundationCompatibilityNormalizer(
            hiddenTemplateAttributeName: hiddenTemplateAttributeName
        ).normalize(data)
        let normalizedHTML = String(decoding: normalizedData, as: UTF8.self)
        guard let document = try? XMLDocument(
            xmlString: normalizedHTML,
            options: [
                .documentTidyHTML,
                .nodeLoadExternalEntitiesNever,
            ]
        ) else {
            return nil
        }
        return plainText(
            from: document,
            sourceLength: sourceLength,
            hiddenTemplateAttributeName: hiddenTemplateAttributeName
        )
    }

    private func plainText(
        from document: XMLDocument,
        sourceLength: Int,
        hiddenTemplateAttributeName: String
    ) -> String? {
        guard let root = document.rootElement() else { return nil }
        var output = ""
        var outputCharacterCount = 0
        output.reserveCapacity(min(sourceLength, 16_384))
        guard appendVisibleText(
            from: root,
            preservingWhitespace: false,
            to: &output,
            outputCharacterCount: &outputCharacterCount,
            hiddenTemplateAttributeName: hiddenTemplateAttributeName
        ) else {
            return nil
        }

        while output.last == "\n" {
            output.removeLast()
            outputCharacterCount -= 1
        }
        return output.isEmpty ? nil : output
    }

    private func appendVisibleText(
        from node: XMLNode,
        preservingWhitespace: Bool,
        to output: inout String,
        outputCharacterCount: inout Int,
        hiddenTemplateAttributeName: String
    ) -> Bool {
        switch node.kind {
        case .text:
            guard let text = node.stringValue else { return true }
            return appendText(
                text,
                preservingWhitespace: preservingWhitespace,
                to: &output,
                outputCharacterCount: &outputCharacterCount
            )
        case .element:
            let name = node.name?.lowercased() ?? ""
            let isNormalizedTemplate = name == "div"
                && (node as? XMLElement)?.attribute(
                    forName: hiddenTemplateAttributeName
                ) != nil
            guard !Self.hiddenBlockTags.contains(name),
                  !isNormalizedTemplate else {
                return true
            }

            if name == "br" {
                return appendBlockBoundary(
                    to: &output,
                    outputCharacterCount: &outputCharacterCount
                )
            }

            let isBlock = Self.blockBoundaryTags.contains(name)
            if isBlock {
                guard appendBlockBoundary(
                    to: &output,
                    outputCharacterCount: &outputCharacterCount
                ) else {
                    return false
                }
            }
            let childPreservesWhitespace =
                preservingWhitespace || Self.preformattedTags.contains(name)
            for child in node.children ?? [] {
                guard appendVisibleText(
                    from: child,
                    preservingWhitespace: childPreservesWhitespace,
                    to: &output,
                    outputCharacterCount: &outputCharacterCount,
                    hiddenTemplateAttributeName: hiddenTemplateAttributeName
                ) else {
                    return false
                }
            }
            if isBlock {
                return appendBlockBoundary(
                    to: &output,
                    trimmingTrailingSpaces: !childPreservesWhitespace,
                    outputCharacterCount: &outputCharacterCount
                )
            }
            return true
        default:
            return true
        }
    }

    private func appendText(
        _ text: String,
        preservingWhitespace: Bool,
        to output: inout String,
        outputCharacterCount: inout Int
    ) -> Bool {
        if preservingWhitespace {
            let textCharacterCount = text.count
            guard textCharacterCount
                    <= Self.maximumOutputCharacterCount
                        - outputCharacterCount else {
                return false
            }
            output.append(contentsOf: text)
            outputCharacterCount += textCharacterCount
            return true
        }

        for character in text {
            if character.isWhitespace {
                if !output.isEmpty,
                   output.last != " ",
                   output.last != "\n" {
                    guard outputCharacterCount
                            < Self.maximumOutputCharacterCount else {
                        return false
                    }
                    output.append(" ")
                    outputCharacterCount += 1
                }
            } else {
                guard outputCharacterCount
                        < Self.maximumOutputCharacterCount else {
                    return false
                }
                output.append(character)
                outputCharacterCount += 1
            }
        }
        return true
    }

    private func appendBlockBoundary(
        to output: inout String,
        trimmingTrailingSpaces: Bool = true,
        outputCharacterCount: inout Int
    ) -> Bool {
        guard !output.isEmpty, output.last != "\n" else { return true }
        if trimmingTrailingSpaces {
            while output.last == " " {
                output.removeLast()
                outputCharacterCount -= 1
            }
        }
        if !output.isEmpty {
            guard outputCharacterCount
                    < Self.maximumOutputCharacterCount else {
                return false
            }
            output.append("\n")
            outputCharacterCount += 1
        }
        return true
    }
}
