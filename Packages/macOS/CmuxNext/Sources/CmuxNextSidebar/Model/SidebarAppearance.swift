public import CmuxNextDesign
import Foundation

/// Workspace icon: an SF Symbol (optionally tinted) or a color swatch.
public nonisolated enum WorkspaceIcon: Hashable, Sendable {
    case symbol(String, tint: GroupColor? = nil)
    case swatch(GroupColor)
    /// One emoji, drawn as text.
    case emoji(String)

    /// The workspace record's `icon` string: one emoji, else an SF Symbol
    /// name (workspace-metadata-v1; plans/cmux-next/sidebar-sections.md 9a).
    public static func parse(_ value: String) -> WorkspaceIcon {
        isEmoji(value) ? .emoji(value) : .symbol(value)
    }

    /// One grapheme that is an emoji (a presentation emoji, or a sequence
    /// such as a flag, a keycap or a ZWJ family).
    public static func isEmoji(_ value: String) -> Bool {
        guard value.count == 1, let first = value.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (value.unicodeScalars.count > 1 && first.properties.isEmoji)
    }
}

/// How the sidebar occupies the window: fully shown at the user's width,
/// or fully hidden (zero width, content reaches the window edge). There is
/// no intermediate state.
public nonisolated enum SidebarPresentation: Hashable, Sendable {
    case shown
    case hidden
}
