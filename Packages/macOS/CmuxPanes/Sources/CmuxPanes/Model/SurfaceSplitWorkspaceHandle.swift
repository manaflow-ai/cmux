public import Bonsplit
public import Foundation

/// The per-workspace surface-navigation, split-creation, and split-operation
/// operations ``SurfaceSplitCoordinator`` drives against a single target
/// workspace.
///
/// The concrete workspace lives in the app target (it owns the Bonsplit split
/// tree, the terminal `TerminalPanel` instances, and the focus/layout state), so
/// a lower package cannot import it. Instead the app-target workspace conforms to
/// this protocol and the coordinator forwards each navigation/creation/operation
/// through it, receiving the created panel's id (`UUID`) rather than the app-owned
/// panel reference.
///
/// Each member is the seam for one operation the legacy `TabManager` surface
/// navigation / split-creation / split-operation bodies read off the resolved
/// `Workspace`: the four surface-selection commands, the split-zoom clear, the
/// focused-pane terminal creation, the explicit-source terminal split, the focus
/// move, the resize divider reads, the toggle-zoom, the panel-close, and the
/// panel-existence / surface-id resolution the stale-close guard performs.
///
/// The members whose names match the `Workspace` method one-for-one
/// (`focusedPanelId`, `hasPanel`, `surfaceIdFromPanelId`, `paneId`,
/// `bonsplitController`, the four `select*Surface` commands, `clearSplitZoom`,
/// `toggleSplitZoom`, `moveFocus`, `closePanel`) are witnessed by the existing
/// `Workspace` members directly. The two creation members carry a `surfaceSplit`
/// prefix (``surfaceSplitNewTerminalSurfaceInFocusedPane(focus:initialInput:)``
/// and ``surfaceSplitNewTerminalSplit(from:...)``) because they convert the
/// `Workspace`'s `TerminalPanel?` return to a `UUID?` at the boundary, and a
/// same-name-same-arity method differing only by return type would make the
/// existing `Workspace` call sites ambiguous.
///
/// `@MainActor` because every operation mutates AppKit/Bonsplit/terminal state on
/// the main thread, matching the callers (keyboard shortcuts, command palette,
/// menu, the command socket) — the seam lives where its callers live.
@MainActor
public protocol SurfaceSplitWorkspaceHandle: AnyObject {
    /// The workspace's currently focused panel id, if any (legacy
    /// `workspace.focusedPanelId`).
    var focusedPanelId: UUID? { get }

    /// Whether the workspace currently holds a panel with `panelId` (legacy
    /// `workspace.panels[panelId] != nil`).
    func hasPanel(_ panelId: UUID) -> Bool

    /// Resolves the Bonsplit surface id owning `panelId`, or `nil` (legacy
    /// `workspace.surfaceIdFromPanelId(_:)`).
    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID?

    /// Resolves the pane id owning `panelId`, or `nil` (legacy
    /// `workspace.paneId(forPanelId:)`).
    func paneId(forPanelId panelId: UUID) -> PaneID?

    /// The live Bonsplit controller backing this workspace's split tree (legacy
    /// `workspace.bonsplitController`). The resize body reads
    /// `allPaneIds`/`treeSnapshot()` from it and ``PaneLayoutService`` applies the
    /// planned divider move to it.
    var bonsplitController: BonsplitController { get }

    // MARK: - Surface navigation (legacy `Workspace` commands)

    /// Selects the next surface in the focused pane (legacy
    /// `workspace.selectNextSurface()`).
    func selectNextSurface()

    /// Selects the previous surface in the focused pane (legacy
    /// `workspace.selectPreviousSurface()`).
    func selectPreviousSurface()

    /// Selects the surface at `index` in the focused pane (legacy
    /// `workspace.selectSurface(at:)`).
    func selectSurface(at index: Int)

    /// Selects the last surface in the focused pane (legacy
    /// `workspace.selectLastSurface()`).
    func selectLastSurface()

    // MARK: - Split zoom / creation / operations (legacy `Workspace` commands)

    /// Clears any split-zoom on this workspace, returning whether a zoom was
    /// cleared (legacy `workspace.clearSplitZoom() -> Bool`, whose result the
    /// `TabManager` call sites discarded).
    @discardableResult
    func clearSplitZoom() -> Bool

    /// Creates a new terminal surface in the focused pane, returning the created
    /// panel's id (legacy
    /// `workspace.newTerminalSurfaceInFocusedPane(focus:initialInput:)?.id`).
    @discardableResult
    func surfaceSplitNewTerminalSurfaceInFocusedPane(focus: Bool, initialInput: String?) -> UUID?

    /// Creates a new terminal split from `panelId`, returning the created panel's
    /// id (legacy `workspace.newTerminalSplit(from:orientation:insertFirst:focus:
    /// workingDirectory:initialCommand:tmuxStartCommand:startupEnvironment:
    /// initialDividerPosition:remotePTYSessionID:)?.id`).
    @discardableResult
    func surfaceSplitNewTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        initialDividerPosition: CGFloat?,
        remotePTYSessionID: String?
    ) -> UUID?

    /// Moves focus in `direction` (legacy `workspace.moveFocus(direction:)`).
    func moveFocus(direction: NavigationDirection)

    /// Toggles split-zoom on `panelId`, returning whether the toggle took
    /// (legacy `workspace.toggleSplitZoom(panelId:)`).
    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool

    /// Closes the panel `panelId`, returning whether the close took (legacy
    /// `workspace.closePanel(_:force:) -> Bool` with `force` defaulted, whose
    /// result the `TabManager.closeSurface` body discarded).
    @discardableResult
    func closePanel(_ panelId: UUID, force: Bool) -> Bool
}
