public import Foundation

/// Seam exposing the app-target bonsplit tab-transfer reads and workspace-move
/// operations that ``SidebarBonsplitTabDropDelegate`` needs, so the delegate
/// lives in `CmuxSidebarUI` without importing the app-target `TabManager`,
/// `AppDelegate`, or `BonsplitTabTransferPasteboard`.
///
/// The app supplies a `@MainActor` adapter that forwards these to the hovered
/// window's `TabManager` plus `AppDelegate.shared` bonsplit routing, matching
/// the legacy delegate's direct `AppDelegate.shared` / `tabManager` lookups.
@MainActor
public protocol SidebarBonsplitTabDropHosting {
    /// The exported UTI string for the bonsplit tab-transfer drag pasteboard,
    /// used to gate `validateDrop` to bonsplit tab drags.
    var bonsplitTabTransferTypeIdentifier: String { get }

    /// The tab id of the active same-process bonsplit transfer on the drag
    /// pasteboard, or `nil` when there is no routable transfer.
    func currentBonsplitTransferTabId() -> UUID?

    /// The workspace id currently hosting the bonsplit tab, when its surface is
    /// locatable in this process.
    func bonsplitSurfaceWorkspaceId(forTab tabId: UUID) -> UUID?

    /// Moves the bonsplit tab onto the target workspace, focusing it and its
    /// window.
    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace workspaceId: UUID,
        focus: Bool,
        focusWindow: Bool
    ) -> Bool

    /// The live workspace ids in sidebar order, for selection-anchor sync after
    /// a move.
    var destinationTabIds: [UUID] { get }

    /// The currently selected workspace id.
    var destinationSelectedTabId: UUID? { get }
}
