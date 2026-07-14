import Foundation
import SwiftUI

/// Renders document-level Markdown with Foundation's native syntax support.
struct ChatArtifactMarkdownView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            Text(renderedMarkdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private var renderedMarkdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}
