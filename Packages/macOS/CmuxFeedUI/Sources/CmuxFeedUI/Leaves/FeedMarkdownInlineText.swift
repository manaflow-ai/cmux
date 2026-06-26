import Foundation
public import SwiftUI

/// Renders a short string as inline-only markdown (bold/italic/code spans),
/// falling back to the raw text when parsing fails. Used by Feed rows that show
/// agent-authored prose without block layout.
public struct FeedMarkdownInlineText: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight?
    let foregroundColor: Color

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
