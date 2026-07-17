import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct FeedMarkdownInlineText: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight?
    let foregroundColor: Color

    init(
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

    var body: some View {
        let parsed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        Text(parsed)
            .cmuxFont(size: fontSize, weight: weight ?? .regular)
            .foregroundColor(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Renders plan text as a stack of small structured sections. Block
/// headings, lists, and paragraphs keep the Feed's compact rhythm, while
/// Claude markdown inside each line gets parsed tastefully. Heading text
/// intentionally stays at body scale.
