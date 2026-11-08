import Foundation

/// Immutable settings used to render the window's workspace pane overlay.
struct TmuxWorkspacePaneOverlaySettings: Equatable, Sendable {
    /// The normalized active pane border color; `nil` hides the border.
    let activePaneBorderColorHex: String?
    /// The right sidebar owns input focus, which hides the border.
    let rightSidebarOwnsInputFocus: Bool
    /// The unread ring and flash color.
    let workspaceAttentionColor: WorkspaceAttentionColor
}
