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
    private static let maximumNestingDepth = 256

    private static let hiddenBlockTags: Set<String> = [
        "head",
        "iframe",
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
        outcome(from: html).plainText
    }

    func outcome(from html: String) -> HTMLPlainTextParseOutcome {
        guard html.utf8.count <= Self.maximumInputByteCount else {
            return .rejected
        }
        return outcome(fromBoundedHTML: html)
    }

    func plainText(from data: Data) -> String? {
        outcome(from: data).plainText
    }

    func outcome(from data: Data) -> HTMLPlainTextParseOutcome {
        guard data.count <= Self.maximumInputByteCount else {
            return .rejected
        }
        guard let html = decodeHTML(from: data),
              html.utf8.count <= Self.maximumInputByteCount else {
            return .rejected
        }
        return outcome(fromBoundedHTML: html)
    }

    private func decodeHTML(from data: Data) -> String? {
        let byteOrderMark = data.prefix(2)
        if byteOrderMark.elementsEqual([0xFF, 0xFE])
            || byteOrderMark.elementsEqual([0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func outcome(
        fromBoundedHTML html: String
    ) -> HTMLPlainTextParseOutcome {
        let hiddenTemplateAttributeName =
            "data-cmux-hidden-template-\(UUID().uuidString.lowercased())"
        let normalizedData = HTMLFoundationCompatibilityNormalizer(
            hiddenTemplateAttributeName: hiddenTemplateAttributeName
        ).normalize(Data(html.utf8))
        let normalizedHTML = String(decoding: normalizedData, as: UTF8.self)
        guard let document = try? XMLDocument(
            xmlString: normalizedHTML,
            options: [
                .documentTidyHTML,
                .nodeLoadExternalEntitiesNever,
            ]
        ) else {
            return .rejected
        }
        return outcome(
            from: document,
            sourceLength: html.utf8.count,
            hiddenTemplateAttributeName: hiddenTemplateAttributeName
        )
    }

    private func outcome(
        from document: XMLDocument,
        sourceLength: Int,
        hiddenTemplateAttributeName: String
    ) -> HTMLPlainTextParseOutcome {
        guard let root = document.rootElement() else { return .rejected }
        var output = ""
        var outputCharacterCount = 0
        output.reserveCapacity(min(sourceLength, 16_384))
        guard appendVisibleText(
            from: root,
            depth: 0,
            preservingWhitespace: false,
            visibilityHidden: false,
            to: &output,
            outputCharacterCount: &outputCharacterCount,
            hiddenTemplateAttributeName: hiddenTemplateAttributeName
        ) else {
            return .rejected
        }

        while output.last == "\n" {
            output.removeLast()
            outputCharacterCount -= 1
        }
        return output.isEmpty ? .noVisibleText : .visibleText(output)
    }

    private func appendVisibleText(
        from node: XMLNode,
        depth: Int,
        preservingWhitespace: Bool,
        visibilityHidden: Bool,
        to output: inout String,
        outputCharacterCount: inout Int,
        hiddenTemplateAttributeName: String
    ) -> Bool {
        guard depth <= Self.maximumNestingDepth else { return false }
        switch node.kind {
        case .text:
            guard !visibilityHidden else { return true }
            guard let text = node.stringValue else { return true }
            return appendText(
                text,
                preservingWhitespace: preservingWhitespace,
                to: &output,
                outputCharacterCount: &outputCharacterCount
            )
        case .element:
            let name = node.name?.lowercased() ?? ""
            let element = node as? XMLElement
            let isNormalizedTemplate = name == "div"
                && element?.attribute(
                    forName: hiddenTemplateAttributeName
                ) != nil
            let visibility = Self.visibilityState(element)
            guard !Self.hiddenBlockTags.contains(name),
                  !isNormalizedTemplate,
                  !visibility.hidesSubtree else {
                return true
            }
            let elementVisibilityHidden = visibility.isHidden
                ?? visibilityHidden

            if name == "br" {
                guard !elementVisibilityHidden else { return true }
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
                    depth: depth + 1,
                    preservingWhitespace: childPreservesWhitespace,
                    visibilityHidden: elementVisibilityHidden,
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

    private static func visibilityState(
        _ element: XMLElement?
    ) -> (hidesSubtree: Bool, isHidden: Bool?) {
        guard let attributes = element?.attributes else {
            return (false, nil)
        }
        if attributes.contains(where: {
            $0.name?.caseInsensitiveCompare("hidden") == .orderedSame
        }) {
            return (true, nil)
        }
        guard let style = attributes.first(where: {
            $0.name?.caseInsensitiveCompare("style") == .orderedSame
        })?.stringValue else {
            return (false, nil)
        }
        return inlineStyleVisibility(style)
    }

    private static func inlineStyleVisibility(
        _ style: String
    ) -> (hidesSubtree: Bool, isHidden: Bool?) {
        var display: (value: String, important: Bool)?
        var visibility: (value: String, important: Bool)?
        for declaration in style.split(separator: ";") {
            guard let separator = declaration.firstIndex(of: ":") else {
                continue
            }
            let property = declaration[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard property == "display" || property == "visibility" else {
                continue
            }
            var value = declaration[declaration.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let importantSuffix = "!important"
            let isImportant = value.hasSuffix(importantSuffix)
            if isImportant {
                value.removeLast(importantSuffix.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let candidate = (value: value, important: isImportant)
            if property == "display" {
                if display?.important != true || isImportant {
                    display = candidate
                }
            } else if visibility?.important != true || isImportant {
                visibility = candidate
            }
        }
        let isHidden: Bool?
        switch visibility?.value {
        case "hidden", "collapse":
            isHidden = true
        case "visible", "initial":
            isHidden = false
        default:
            isHidden = nil
        }
        return (display?.value == "none", isHidden)
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
