public import SwiftUI

/// Renders a single line of agent text, parsing Claude inline markdown
/// (bold, italics, code) while preserving whitespace. Falls back to the raw
/// string when the markdown parser rejects the input.
public struct FeedMarkdownInlineText: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight?
    let foregroundColor: Color

    /// Creates an inline-markdown text view.
    /// - Parameters:
    ///   - text: The line of agent text to render.
    ///   - fontSize: Point size for the rendered text.
    ///   - weight: Optional font weight; the system default is used when `nil`.
    ///   - foregroundColor: Color applied to the rendered text.
    public init(
        text: String,
        fontSize: CGFloat,
        weight: Font.Weight? = nil,
        foregroundColor: Color
    ) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        self.foregroundColor = foregroundColor
    }

    public var body: some View {
        let parsed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        let font = weight.map { Font.system(size: fontSize, weight: $0) }
            ?? Font.system(size: fontSize)
        Text(parsed)
            .font(font)
            .foregroundColor(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}
