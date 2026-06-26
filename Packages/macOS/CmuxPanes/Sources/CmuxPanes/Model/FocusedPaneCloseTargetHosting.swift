public import Foundation
public import Bonsplit

/// The workspace-side seam ``FocusedPaneCloseTargetPlanner`` reads to derive the
/// focused-pane close targets through.
///
/// **Why a synchronous read protocol and not a value snapshot.** Each derivation
/// the planner performs (``FocusedPaneCloseTargetPlanner/closeOtherTabsPlan()``,
/// ``FocusedPaneCloseTargetPlanner/shortcutCloseTargetPanelId()``,
/// ``FocusedPaneCloseTargetPlanner/shouldCloseWorkspaceOnLastSurfaceShortcut(panelId:keepWorkspaceOpenWhenClosingLastSurface:)``,
/// ``FocusedPaneCloseTargetPlanner/workspaceNeedsConfirmClose()``) runs as one
/// `@MainActor` turn that queries the authoritative `BonsplitController` split
/// tree and the workspace's panel bookkeeping, exactly as the legacy
/// `TabManager` close-target bodies did. Capturing all of that into a snapshot
/// (ordered tabs per pane, the surface-id-to-panel-id map, pin state, titles)
/// would duplicate live state the workspace already owns; the planner reads it
/// through this seam so it never holds the app-target `Workspace`, while every
/// value it sees stays on the live state.
///
/// The bonsplit reads (`focusedBonsplitPaneId`, `allBonsplitPaneIds`,
/// `tabs(inPane:)`, `selectedTab(inPane:)`) and the panel-resolution reads
/// (`panelId(forSurfaceId:)`, `hasPanel(_:)`) are the same requirements the
/// sibling ``SplitMoveReorderHosting`` / ``SurfaceLifecycleHosting`` already
/// declare; a single `Workspace` implementation satisfies all of them. The
/// remaining reads mirror legacy `Workspace` members one-for-one:
/// `focusedPanelId` is `Workspace.focusedPanelId`, `panelCount` is
/// `panels.count`, `firstPanelId` is `panels.keys.first`, `isPanelPinned(_:)`
/// is the identically named helper, `needsConfirmClose()` is the identically
/// named helper, and `panelDisplayTitle(panelId:)` keeps the localized
/// `CloseOtherTabsConfirmationPrompt.displayTitle(panelTitle(panelId:))`
/// computation app-side.
@MainActor
public protocol FocusedPaneCloseTargetHosting: AnyObject {
    // MARK: Panel resolution / pinning (legacy `Workspace` helpers)

    /// Resolves the panel id owning the given bonsplit surface id, or `nil`
    /// (legacy `Workspace.panelIdFromSurfaceId`).
    func panelId(forSurfaceId surfaceId: TabID) -> UUID?

    /// Whether the workspace currently owns a panel with the given id (legacy
    /// `Workspace.panels[panelId] != nil`).
    func hasPanel(_ panelId: UUID) -> Bool

    /// Whether the panel is pinned (legacy `Workspace.isPanelPinned`).
    func isPanelPinned(_ panelId: UUID) -> Bool

    /// The display title for the panel, collapsed for the confirmation prompt
    /// (legacy `CloseOtherTabsConfirmationPrompt.displayTitle(Workspace.panelTitle(panelId:))`).
    func panelDisplayTitle(panelId: UUID) -> String

    // MARK: Panel inventory (legacy `Workspace.panels`)

    /// The currently focused panel id (legacy `Workspace.focusedPanelId`).
    var focusedPanelId: UUID? { get }

    /// The number of panels (legacy `Workspace.panels.count`).
    var panelCount: Int { get }

    /// The first panel id in dictionary order, or `nil` (legacy
    /// `Workspace.panels.keys.first`).
    var firstPanelId: UUID? { get }

    // MARK: Bonsplit pass-throughs

    /// Every pane id (legacy `bonsplitController.allPaneIds`).
    var allBonsplitPaneIds: [PaneID] { get }

    /// The currently focused pane id (legacy
    /// `bonsplitController.focusedPaneId`).
    var focusedBonsplitPaneId: PaneID? { get }

    /// The pane's tabs in tab order (legacy `bonsplitController.tabs(inPane:)`).
    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab]

    /// The pane's selected tab (legacy `bonsplitController.selectedTab(inPane:)`).
    func selectedTab(inPane paneId: PaneID) -> Bonsplit.Tab?

    // MARK: Workspace close gating (legacy `Workspace.needsConfirmClose`)

    /// Whether closing the workspace needs confirmation (legacy
    /// `Workspace.needsConfirmClose()`).
    func needsConfirmClose() -> Bool
}
