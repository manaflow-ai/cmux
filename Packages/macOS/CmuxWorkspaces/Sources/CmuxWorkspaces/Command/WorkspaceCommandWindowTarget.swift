public import Foundation

/// A "Move Workspace to Window" destination the workspace-command menu renders,
/// lifted out of the app target's `AppDelegate.WindowMoveTarget` view-data type.
///
/// The coordinator asks the host (``WorkspaceCommandHosting``) to enumerate the
/// other live windows the selected workspace can move into, and surfaces them as
/// these `Sendable` value rows. The app's `WindowMoveTarget` carries a live
/// `TabManager` reference for other call sites; the menu only ever reads the
/// destination `windowId`, its `label`, and whether it is the current window, so
/// this is the exact subset the command surface needs and nothing of the god
/// object crosses the module boundary.
public struct WorkspaceCommandWindowTarget: Identifiable, Sendable, Equatable {
    /// The destination window's identifier.
    public let windowId: UUID
    /// The destination window's menu label (already localized/resolved app-side).
    public let label: String
    /// Whether this row is the workspace's current window (rendered disabled).
    public let isCurrentWindow: Bool

    /// `Identifiable` identity is the destination window id (matches the legacy
    /// `WindowMoveTarget.id`).
    public var id: UUID { windowId }

    /// Creates a window-move destination row.
    public init(windowId: UUID, label: String, isCurrentWindow: Bool) {
        self.windowId = windowId
        self.label = label
        self.isCurrentWindow = isCurrentWindow
    }
}
