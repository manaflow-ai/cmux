public import Foundation

/// One existing-workspace destination a "Move Tab To…" surface move can target.
///
/// The value projection of the legacy nested `AppDelegate.WorkspaceMoveTarget`,
/// owned here so the surface-move coordinator (``PaneSurfaceMoveCoordinator``)
/// can build and return the destination list without naming any app type. The
/// legacy struct also carried the destination's live `TabManager`; that handle
/// is irreducibly app-coupled and never read by the move-target consumers (the
/// context menu and the terminal NSView submenu only read ``workspaceId`` and
/// ``label``), so it is dropped from the value type. The app shim resolves the
/// `TabManager` again by ``workspaceId`` when it applies a chosen target.
///
/// `Sendable, Equatable` value type with no app reach, so the move-target
/// resolution is trivially testable.
public struct WorkspaceMoveTarget: Identifiable, Sendable, Equatable {
    /// The window that owns the destination workspace.
    public let windowId: UUID
    /// The destination workspace's identifier.
    public let workspaceId: UUID
    /// The label of the destination window (e.g. "Current Window", "Window 2").
    public let windowLabel: String
    /// The destination workspace's display title.
    public let workspaceTitle: String
    /// Whether the destination window is the reference (current) window.
    public let isCurrentWindow: Bool

    /// The stable identity used by the menu/submenu list.
    public var id: String { "\(windowId.uuidString):\(workspaceId.uuidString)" }

    /// The label shown in the move-destination menu: the workspace title in the
    /// current window, otherwise the title plus the window label in parentheses.
    public var label: String {
        isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
    }

    /// Creates a move target from its window/workspace identity, labels, and
    /// current-window flag.
    public init(
        windowId: UUID,
        workspaceId: UUID,
        windowLabel: String,
        workspaceTitle: String,
        isCurrentWindow: Bool
    ) {
        self.windowId = windowId
        self.workspaceId = workspaceId
        self.windowLabel = windowLabel
        self.workspaceTitle = workspaceTitle
        self.isCurrentWindow = isCurrentWindow
    }
}
