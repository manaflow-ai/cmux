import SwiftUI

/// Embeds document-level markdown rendering inside a host surface.
///
/// Public wrapper over the artifact viewer's markdown route content for hosts
/// that fetch and decode their own bytes (like the panel-scoped markdown
/// surface on iOS) but should render identically to the modal viewer.
public struct ChatArtifactEmbeddedMarkdown: View {
    private let markdown: String

    /// Creates an embedded markdown renderer for already-decoded text.
    public init(markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        ChatArtifactMarkdownView(markdown: markdown)
    }
}
