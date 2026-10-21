#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Inline markdown (bold, italic, code, links, strikethrough) to a styled
/// `AttributedString`, following SPEC 2.2: inline code mono on `fill`, links
/// underlined in `label` (no blue). Results are cached by source text since
/// committed blocks never change and the streaming tail changes every tick.
@MainActor
public final class InlineMarkdownCache {
    public static let shared = InlineMarkdownCache()
    private var cache: [String: AttributedString] = [:]
    private var order: [String] = []
    private let limit = 800

    public func attributed(_ source: String, baseFont: Font = .body) -> AttributedString {
        let key = source
        if let hit = cache[key] { return hit }
        let value = Self.render(source)
        cache[key] = value
        order.append(key)
        if order.count > limit {
            cache[order.removeFirst()] = nil
        }
        return value
    }

    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent else {
                if run.link != nil {
                    result[run.range].underlineStyle = .single
                    result[run.range].foregroundColor = .primary
                }
                continue
            }
            if intent.contains(.code) {
                // No explicit font: Text draws the code intent in the
                // monospaced variant of the surrounding font, so code in a
                // plan step or table cell matches its text size.
                result[run.range].backgroundColor = Color.cmuxMobileFill
            }
            if run.link != nil {
                result[run.range].underlineStyle = .single
                result[run.range].foregroundColor = .primary
            }
        }
        return result
    }
}

/// Inline text view used by every block.
struct InlineText: View {
    let source: String
    var font: Font = .body

    var body: some View {
        Text(InlineMarkdownCache.shared.attributed(source))
            .font(font)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
