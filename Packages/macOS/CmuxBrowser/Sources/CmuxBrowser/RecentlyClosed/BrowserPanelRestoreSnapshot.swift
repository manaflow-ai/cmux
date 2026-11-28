public import Foundation

/// The identity a recently-closed browser entry needs for stack bookkeeping:
/// which workspace owned the panel and when it closed.
///
/// The full restore payload (URL, profile, pane/tab placement, split
/// fallback) is `Workspace`-owned and lands in its own browser-panel package
/// in the Workspace decomposition; this package only depends on the two
/// fields the recency stack reads, so the stack and model lift now without
/// dragging the workspace god file's types along.
public protocol BrowserPanelRestoreSnapshot: Sendable {
    /// The workspace that owned the closed browser panel.
    var workspaceId: UUID { get }
    /// When the panel was closed.
    var closedAt: Date { get }
}
