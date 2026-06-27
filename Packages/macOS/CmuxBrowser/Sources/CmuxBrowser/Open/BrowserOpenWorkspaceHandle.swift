public import Bonsplit
public import Foundation

/// The per-workspace browser-panel creation operations
/// ``BrowserOpenCoordinator`` drives against a single target workspace.
///
/// The concrete workspace lives in the app target (it owns the Bonsplit split
/// tree, the WebKit `BrowserPanel` instances, and the focus/layout state), so a
/// lower package cannot import it. Instead the app-target workspace conforms to
/// this protocol and the coordinator forwards each creation/lookup through it,
/// receiving the created panel's id (`UUID`) rather than the app-owned panel
/// reference.
///
/// Each method is the seam for one operation the legacy
/// `TabManager.openBrowser`/`newBrowserSplit`/`newBrowserSurface` bodies read
/// off the resolved `Workspace`:
/// `topRightBrowserReusePane()`, `newBrowserSurface(inPane:…)`,
/// `newBrowserSplit(from:…)`, `focusedPanelId`, the panel-existence check, the
/// remembered focused panel id, the sidebar-ordered panel ids, and the
/// focused-or-first Bonsplit pane id used by the default open path.
///
/// `@MainActor` because every operation mutates WebKit/AppKit/Bonsplit state on
/// the main thread, matching the callers (keyboard shortcuts, command palette,
/// menu, the command socket) — the seam lives where its callers live.
@MainActor
public protocol BrowserOpenWorkspaceHandle: AnyObject {
    /// The workspace's currently focused panel id, if any
    /// (legacy `workspace.focusedPanelId`).
    var focusedPanelId: UUID? { get }

    /// Whether the workspace currently holds a panel with `panelId`
    /// (legacy `workspace.panels[panelId] != nil`).
    func hasPanel(_ panelId: UUID) -> Bool

    /// The workspace's panel ids in sidebar order
    /// (legacy `workspace.sidebarOrderedPanelIds()`).
    func sidebarOrderedPanelIds() -> [UUID]

    /// All panel ids sorted by `uuidString`, the deterministic last-resort
    /// split source (legacy `workspace.panels.keys.sorted { … }`).
    func panelIdsSortedByUUIDString() -> [UUID]

    /// The Bonsplit pane to open a default browser surface into: the focused
    /// pane, else the first pane (legacy
    /// `workspace.bonsplitController.focusedPaneId ?? …allPaneIds.first`).
    var focusedOrFirstPaneId: PaneID? { get }

    /// The top-right pane a split-right browser open should reuse, if any
    /// (legacy `workspace.topRightBrowserReusePane()`).
    func topRightBrowserReusePane() -> PaneID?

    /// The pane an embedded-link open should reuse for a new browser surface,
    /// found by walking the source panel's split-tree ancestry to the closest
    /// horizontal ancestor where the source is in the first (left) branch
    /// (legacy `workspace.preferredRightSideTargetPane(fromPanelId:)`). `nil`
    /// when no such pane exists, in which case the open splits from the source.
    func preferredRightSideTargetPane(fromPanelId panelId: UUID) -> PaneID?

    /// Creates a new browser surface in `paneId`, returning the created panel's
    /// id (legacy `workspace.newBrowserSurface(inPane:url:focus:insertAtEnd:
    /// preferredProfileID:)?.id`).
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL?,
        focus: Bool,
        insertAtEnd: Bool,
        preferredProfileID: UUID?
    ) -> UUID?

    /// Creates a new browser surface in `paneId` for the plain (non-policy)
    /// `newBrowserSurface(tabId:inPane:…)` wrapper, returning the created panel's
    /// id (legacy `workspace.newBrowserSurface(inPane:url:preferredProfileID:)?.id`).
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL?,
        preferredProfileID: UUID?
    ) -> UUID?

    /// Creates a new browser split from `panelId`, returning the created panel's
    /// id (legacy `workspace.newBrowserSplit(from:orientation:url:
    /// preferredProfileID:focus:)?.id`).
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        url: URL?,
        preferredProfileID: UUID?,
        focus: Bool
    ) -> UUID?

    /// Creates a new browser split from `panelId` for the
    /// `newBrowserSplit(tabId:…)` wrapper, threading the insert-first and
    /// initial-divider-position parameters (legacy
    /// `workspace.newBrowserSplit(from:orientation:insertFirst:url:
    /// preferredProfileID:focus:initialDividerPosition:)?.id`).
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        url: URL?,
        preferredProfileID: UUID?,
        focus: Bool,
        initialDividerPosition: CGFloat?
    ) -> UUID?
}
