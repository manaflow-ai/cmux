import Foundation
import SwiftUI

/// Embeds document-level markdown rendering inside a host surface.
///
/// Public wrapper over the artifact viewer's markdown route content for hosts
/// that fetch and decode their own bytes (like the panel-scoped markdown
/// surface on iOS) but should render identically to the modal viewer.
public struct ChatArtifactEmbeddedMarkdown: View {
    private let markdown: String
    private let documentID: String
    @Environment(\.colorScheme) private var colorScheme

    /// Creates an embedded markdown renderer for already-decoded text.
    public init(markdown: String, documentID: String = "embedded-markdown") {
        self.markdown = markdown
        self.documentID = documentID
    }

    public var body: some View {
        if ChatArtifactMarkdownPresentation(markdown: markdown).mode == .rendered {
            ChatArtifactMarkdownView(markdown: markdown)
        } else {
            largeMarkdownTextView
        }
    }

    @ViewBuilder
    private var largeMarkdownTextView: some View {
        #if canImport(UIKit)
        ChatArtifactTextView(
            documentID: documentID,
            chunks: [markdown],
            reachedEOF: true,
            highlightDecision: .skippedForSize,
            highlightTheme: colorScheme == .dark ? .dark : .light,
            searchQuery: "",
            previousSearchRequestID: 0,
            nextSearchRequestID: 0,
            onSearchSummaryChanged: { _ in },
            lineIndex: largeMarkdownLineIndex,
            showsLineNumbers: false,
            goToLineUTF16Offset: 0,
            goToLineRequestID: 0,
            wrapsLines: true,
            fontPointSize: ChatArtifactTextPreferences.defaultFontSize,
            onFontSizeChanged: { _ in },
            topRequestID: 0,
            bottomRequestID: 0
        )
        #else
        ScrollView(.vertical) {
            Text(markdown)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        #endif
    }

    #if canImport(UIKit)
    private var largeMarkdownLineIndex: ChatArtifactLineIndex {
        var lineIndex = ChatArtifactLineIndex()
        lineIndex.append(markdown)
        return lineIndex
    }
    #endif
}
