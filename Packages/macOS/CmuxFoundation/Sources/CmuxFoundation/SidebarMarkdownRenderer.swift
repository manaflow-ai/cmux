public import Foundation

/// Pure text transform converting a workspace-description markdown string into
/// an `AttributedString`, preserving inline markdown attributes and original
/// whitespace/line breaks.
///
/// Shared foundation utility (not sidebar-specific); used to render workspace
/// descriptions in the sidebar and reusable anywhere a lightweight inline
/// markdown render is needed. Construct it with the markdown source and read
/// ``workspaceDescription``.
public struct SidebarMarkdownRenderer {
    private let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    /// The markdown rendered into an `AttributedString`, interpreting only
    /// inline syntax and preserving whitespace. `nil` when it cannot be parsed.
    public var workspaceDescription: AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}
