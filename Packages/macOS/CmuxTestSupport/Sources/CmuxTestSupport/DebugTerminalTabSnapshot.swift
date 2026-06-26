#if DEBUG
public import Foundation

/// A read-only view of one live workspace tab the Debug-menu color-comparison
/// opener inspects when deciding whether to reuse an existing workspace.
///
/// The legacy `openDebugColorComparisonWorkspaces(_:)` loop builds a
/// title-to-workspace map from `tabManager.tabs`, keyed by each tab's
/// `customTitle`. ``DebugTerminalActionsCoordinator`` rebuilds that map from
/// these snapshots, addressing live workspaces only by their `id`; the app
/// target keeps the mapping from `id` back to the real `Workspace`, which
/// cannot cross the package boundary.
public struct DebugTerminalTabSnapshot: Sendable, Equatable {
    /// The workspace's stable identifier.
    public let id: UUID

    /// The workspace's custom title, or `nil` when it has none (mirrors
    /// `Workspace.customTitle`).
    public let customTitle: String?

    /// Creates a snapshot of a workspace's `id` and `customTitle`.
    public init(id: UUID, customTitle: String?) {
        self.id = id
        self.customTitle = customTitle
    }
}
#endif
