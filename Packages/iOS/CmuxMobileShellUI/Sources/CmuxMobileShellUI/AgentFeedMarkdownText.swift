#if os(iOS)
import Foundation
import SwiftUI

/// Inline Markdown for Feed content that stays inside the row's SwiftUI
/// layout. Document-level content uses the shared artifact renderer instead.
struct AgentFeedMarkdownText: View {
    let markdown: String
    let font: Font
    let color: Color
    let lineLimit: Int?

    init(markdown: String, font: Font, color: Color = .primary, lineLimit: Int? = nil) {
        self.markdown = markdown
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
    }

    var body: some View {
        Text(renderedMarkdown)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
    }

    private var renderedMarkdown: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}
#endif
