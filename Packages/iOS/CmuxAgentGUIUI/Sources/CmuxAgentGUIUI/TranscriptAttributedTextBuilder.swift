#if os(iOS)
import Foundation
import UIKit

struct TranscriptAttributedTextBuilder: Sendable {
    private let traitCollection: UITraitCollection?

    init(traitCollection: UITraitCollection? = nil) {
        self.traitCollection = traitCollection
    }

    func make(text: String, style: TranscriptTextStyle, density: TranscriptDensity) -> TranscriptAttributedText {
        switch style {
        case .agentMarkdown:
            return markdown(text)
        case .body:
            return plain(text, font: preferredFont(forTextStyle: .body))
        case .metadata:
            return plain(text, font: metadataFont(for: density))
        case .metadataEmphasized:
            return plain(text, font: metadataFont(for: density, weight: .semibold))
        case .askPrompt:
            return plain(text, font: preferredFont(forTextStyle: .body).withTraits(.traitBold))
        case .askError:
            return plain(text, font: metadataFont(for: density))
        }
    }

    private func markdown(_ source: String) -> TranscriptAttributedText {
        do {
            let parsed = try AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .full)
            )
            return TranscriptAttributedText(value: renderedMarkdown(parsed))
        } catch {
            return plain(source, font: preferredFont(forTextStyle: .body))
        }
    }

    private func renderedMarkdown(_ source: AttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var currentBlockID: Int?
        var currentBlockStart = 0
        var currentBlockKind: PresentationIntent.Kind?
        var currentIsListItem = false

        for run in source.runs {
            let descriptor = blockDescriptor(run.presentationIntent)
            if descriptor.id != currentBlockID {
                if currentBlockID != nil {
                    applyBlockStyle(
                        to: output,
                        range: NSRange(location: currentBlockStart, length: output.length - currentBlockStart),
                        kind: currentBlockKind,
                        isListItem: currentIsListItem
                    )
                    output.append(NSAttributedString(string: "\n"))
                }
                currentBlockID = descriptor.id
                currentBlockStart = output.length
                currentBlockKind = descriptor.kind
                currentIsListItem = descriptor.isListItem
                if !descriptor.prefix.isEmpty {
                    output.append(NSAttributedString(
                        string: descriptor.prefix,
                        attributes: [.font: preferredFont(forTextStyle: .body)]
                    ))
                }
            }
            let fragment = String(source[run.range].characters)
            output.append(NSAttributedString(
                string: fragment,
                attributes: inlineAttributes(for: run, blockKind: descriptor.kind)
            ))
        }
        if currentBlockID != nil {
            applyBlockStyle(
                to: output,
                range: NSRange(location: currentBlockStart, length: output.length - currentBlockStart),
                kind: currentBlockKind,
                isListItem: currentIsListItem
            )
        }
        if output.length == 0 {
            output.append(NSAttributedString(
                string: String(source.characters),
                attributes: [.font: preferredFont(forTextStyle: .body)]
            ))
        }
        return output
    }

    private func blockDescriptor(
        _ intent: PresentationIntent?
    ) -> (id: Int, kind: PresentationIntent.Kind?, isListItem: Bool, prefix: String) {
        guard let intent, let first = intent.components.first else {
            return (-1, nil, false, "")
        }
        var listOrdinal: Int?
        var isOrdered = false
        var isUnordered = false
        for component in intent.components {
            switch component.kind {
            case .listItem(let ordinal):
                listOrdinal = ordinal
            case .orderedList:
                isOrdered = true
            case .unorderedList:
                isUnordered = true
            default:
                break
            }
        }
        let prefix: String
        if isOrdered, let listOrdinal {
            prefix = "\(listOrdinal). "
        } else if isUnordered {
            prefix = "• "
        } else {
            prefix = ""
        }
        return (first.identity, first.kind, listOrdinal != nil, prefix)
    }

    private func inlineAttributes(
        for run: AttributedString.Runs.Run,
        blockKind: PresentationIntent.Kind?
    ) -> [NSAttributedString.Key: Any] {
        let body = preferredFont(forTextStyle: .body)
        var font = body
        if case .header(let level) = blockKind {
            let pointSize = body.pointSize + (level == 1 ? 3 : level == 2 ? 2 : 0)
            font = UIFont.systemFont(ofSize: pointSize, weight: .bold)
        } else if case .codeBlock = blockKind {
            font = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        }
        if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            font = font.withTraits(.traitBold)
        }
        if run.inlinePresentationIntent?.contains(.emphasized) == true {
            font = font.withTraits(.traitItalic)
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if run.inlinePresentationIntent?.contains(.code) == true {
            attributes[.font] = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
            attributes[.transcriptInlineCode] = true
        }
        if let link = run.link {
            attributes[.link] = link
        }
        return attributes
    }

    private func applyBlockStyle(
        to text: NSMutableAttributedString,
        range: NSRange,
        kind: PresentationIntent.Kind?,
        isListItem: Bool
    ) {
        guard range.length > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = isListItem ? 2 : 8
        if isListItem {
            paragraph.headIndent = 20
            paragraph.firstLineHeadIndent = 0
        }
        if case .codeBlock = kind {
            paragraph.headIndent = 8
            paragraph.firstLineHeadIndent = 8
            paragraph.tailIndent = -8
            paragraph.paragraphSpacingBefore = 4
            paragraph.paragraphSpacing = 8
            text.addAttribute(.transcriptCodeBlock, value: true, range: range)
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }

    private func plain(_ text: String, font: UIFont) -> TranscriptAttributedText {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return TranscriptAttributedText(value: NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: paragraph]
        ))
    }

    private func metadataFont(for density: TranscriptDensity, weight: UIFont.Weight = .regular) -> UIFont {
        let style: UIFont.TextStyle = density == .comfortable ? .footnote : .caption1
        let preferred = preferredFont(forTextStyle: style)
        return UIFont.systemFont(ofSize: preferred.pointSize, weight: weight)
    }

    private func preferredFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: traitCollection)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits)
        ) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

extension NSAttributedString.Key {
    static let transcriptCodeBlock = NSAttributedString.Key("cmux.transcript.codeBlock")
    static let transcriptInlineCode = NSAttributedString.Key("cmux.transcript.inlineCode")
}
#endif
