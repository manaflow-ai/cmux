public import Foundation

/// Pure text transform converting a workspace-description markdown string into
/// an `AttributedString`, preserving inline markdown attributes and original
/// whitespace/line breaks.
///
/// Shared foundation utility (not sidebar-specific); used to render workspace
/// descriptions in the sidebar and reusable anywhere a lightweight inline
/// markdown render is needed.
public enum SidebarMarkdownRenderer {
    /// Renders a workspace-description markdown string into an
    /// `AttributedString`, interpreting only inline syntax and preserving
    /// whitespace. Returns `nil` when the markdown cannot be parsed.
    public static func renderWorkspaceDescription(_ markdown: String) -> AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}
