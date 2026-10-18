import SwiftUI

/// Embeds document-level markdown rendering inside a host surface.
///
/// Public wrapper over the artifact viewer's markdown route content for hosts
/// that fetch and decode their own bytes (like the panel-scoped markdown
/// surface on iOS) but should render identically to the modal viewer.
public struct ChatArtifactEmbeddedMarkdown: View {
    public enum Rendering: Sendable {
        case web
        case native
    }

    private let markdown: String
    private let rendering: Rendering

    /// Creates an embedded markdown renderer for already-decoded text.
    public init(markdown: String, rendering: Rendering = .web) {
        self.markdown = markdown
        self.rendering = rendering
    }

    public var body: some View {
        switch rendering {
        case .web:
            ChatArtifactMarkdownView(markdown: markdown)
        case .native:
            ChatArtifactMarkdownNativeView(markdown: markdown)
        }
    }
}
