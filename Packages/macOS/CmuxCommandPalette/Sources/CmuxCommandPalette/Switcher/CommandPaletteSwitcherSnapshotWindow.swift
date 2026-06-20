public import Foundation

/// A fully resolved switcher window context, produced host-side from live
/// window/tab state and consumed by ``CommandPaletteSwitcherEntryBuilder``.
///
/// One per main window the switcher spans. The host adapter orders the
/// workspaces and (when included) surfaces, resolves the optional window label,
/// and binds each row's activation action; the builder turns the list into the
/// switcher command entries and the change-detection fingerprint. See
/// ``CommandPaletteSwitcherSnapshotSurface`` for why this is not `Sendable`.
public struct CommandPaletteSwitcherSnapshotWindow {
    /// Window id.
    public let windowId: UUID
    /// Optional window label (nil for a single-window switcher).
    public let windowLabel: String?
    /// The window's selected workspace, when any.
    public let selectedWorkspaceId: UUID?
    /// The window's workspaces in switcher order.
    public let workspaces: [CommandPaletteSwitcherSnapshotWorkspace]

    /// Creates a resolved switcher window context.
    public init(
        windowId: UUID,
        windowLabel: String?,
        selectedWorkspaceId: UUID?,
        workspaces: [CommandPaletteSwitcherSnapshotWorkspace]
    ) {
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
    }
}
