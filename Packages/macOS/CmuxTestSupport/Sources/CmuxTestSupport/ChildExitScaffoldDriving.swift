#if DEBUG
public import Foundation

/// The live-action seam the child-exit scaffold runners drive.
///
/// ``ChildExitSplitScaffoldRunner`` and ``ChildExitKeyboardScaffoldRunner`` own
/// the harness *orchestration*: the per-iteration build/exit loop, the layout
/// build order, the readiness gating, and every capture-file write. The
/// operations they sequence (resolving the selected workspace, creating splits,
/// focusing and closing panes, sending shell text, waiting for surface
/// readiness, and observing panel-count / workspace-alive transitions) read and
/// mutate main-actor `Workspace` / Bonsplit / Ghostty state that cannot cross
/// the package boundary, so the app target conforms this protocol and the
/// runners call back through it.
///
/// The runner first calls ``pinSelectedWorkspace()`` to resolve and *retain* the
/// workspace under test for the harness lifetime, exactly as the legacy bodies
/// captured `let tab = selectedWorkspace` once and operated on that strong
/// reference even after it was removed from the open-workspace list. Every later
/// call reads through that pin, so `panelCount`/`focusedPanelId`/etc. reflect the
/// captured workspace, not a fresh `selectedWorkspace` lookup. Panels are
/// identified by their `UUID`; the runner never inspects a live object directly
/// and only reads back scalars and small value tuples.
///
/// Isolation: `@MainActor`, because every operation touches main-actor terminal
/// and window state, matching the legacy bodies that ran on the main actor.
@MainActor
public protocol ChildExitScaffoldDriving: AnyObject {
    /// Resolves and retains the currently selected workspace for the harness
    /// lifetime, returning its id, or `nil` when there is no selected workspace
    /// (the legacy `let tab = selectedWorkspace` capture and guard).
    ///
    /// Every subsequent driver call operates on this pinned workspace, matching
    /// the legacy strong-`tab` capture (which stayed valid after the workspace
    /// left the open list).
    func pinSelectedWorkspace() -> UUID?

    /// The total number of open workspaces (the legacy `tabs.count`). Independent
    /// of the pin.
    var workspaceCount: Int { get }

    /// Whether the pinned workspace is still in the open-workspace list (the
    /// legacy `tabs.contains(where: { $0.id == tab.id })`).
    var pinnedWorkspaceIsAlive: Bool { get }

    /// The pinned workspace's current panel count (the legacy `tab.panels.count`).
    var pinnedPanelCount: Int { get }

    /// The pinned workspace's focused panel id, or `nil` (the legacy
    /// `tab.focusedPanelId`).
    var pinnedFocusedPanelId: UUID? { get }

    /// The pinned workspace's first panel id in dictionary order, or `nil` (the
    /// legacy `tab.panels.keys.first`).
    var pinnedFirstPanelId: UUID? { get }

    /// Every panel id of the pinned workspace except `panelId` (the legacy
    /// `tab.panels.keys where panelId != leftPanelId`).
    func pinnedPanelIds(excluding panelId: UUID) -> [UUID]

    /// Force-closes the pane owning `panelId` on the pinned workspace (the legacy
    /// `tab.closePanel(_:force:true)`).
    func closePinnedPanel(_ panelId: UUID)

    /// Creates a horizontal (right) terminal split from `panelId` on the pinned
    /// workspace, returning the new panel's id, or `nil` on failure (the legacy
    /// `tab.newTerminalSplit(from:orientation:.horizontal)`).
    func newRightSplit(from panelId: UUID) -> UUID?

    /// Creates a vertical (down) terminal split from `panelId` on the pinned
    /// workspace, returning the new panel's id, or `nil` on failure (the legacy
    /// `tab.newTerminalSplit(from:orientation:.vertical)`).
    func newDownSplit(from panelId: UUID) -> UUID?

    /// Focuses the pane owning `panelId` on the pinned workspace (the legacy
    /// `tab.focusPanel(_:)`).
    func focusPinnedPanel(_ panelId: UUID)

    /// Sends `text` to the terminal panel owning `panelId` on the pinned
    /// workspace if it exists (the legacy `panel.sendText(_:)`).
    func sendText(_ panelId: UUID, _ text: String)

    /// Waits, up to `timeoutSeconds`, for the pinned workspace to have exactly
    /// `count` panels, reproducing the legacy `waitForWorkspacePanelsCondition`
    /// with a `panels.count == count` predicate.
    func waitForPanelCount(equals count: Int, timeoutSeconds: TimeInterval) async -> Bool

    /// Waits, up to `timeoutSeconds`, for `panelId` to be removed from the pinned
    /// workspace, reproducing the legacy `waitForWorkspacePanelsCondition` with a
    /// `panels[panelId] == nil` predicate.
    func waitForPanelRemoved(_ panelId: UUID, timeoutSeconds: TimeInterval) async -> Bool

    /// Waits, up to `timeoutSeconds`, for `panelId`'s terminal surface to be
    /// attached to the window with a non-nil surface, reproducing the legacy
    /// `waitForTerminalPanelCondition` with the `isViewInWindow && surface != nil`
    /// predicate.
    func waitForPanelAttachedWithSurface(_ panelId: UUID, timeoutSeconds: TimeInterval) async -> Bool

    /// Waits, up to 8 seconds, for the pinned workspace's panel count to reach
    /// `1`, reproducing the child-exit split harness's inline
    /// `withCheckedContinuation` on
    /// `panelsPublisher.map { $0.count }.removeDuplicates()`.
    func waitForPanelCountToCollapse() async -> Bool

    /// Awaits `panelId`'s readiness on the pinned workspace and reports
    /// `(attached, hasSurface, firstResponder)`, reproducing the legacy
    /// `waitForTerminalPanelReadyForUITest`.
    func waitForPanelReady(_ panelId: UUID) async -> ChildExitPanelReadiness

    /// Reads `panelId`'s current attached / has-surface flags on the pinned
    /// workspace without waiting, or `nil` when the panel is absent, reproducing
    /// the legacy early-trigger branch's direct surface reads.
    func panelReadinessSnapshot(_ panelId: UUID) -> ChildExitPanelReadiness?

    /// Converges AppKit first responder onto the focused terminal (the legacy
    /// `ensureFocusedTerminalFirstResponder`).
    func ensureFocusedTerminalFirstResponder()

    /// The pinned workspace's id as a string (the legacy `tab.id.uuidString`).
    var pinnedWorkspaceIdString: String { get }

    /// The pinned workspace's focused panel id as a string, or `""` (the legacy
    /// `tab.focusedPanelId?.uuidString ?? ""`).
    var pinnedFocusedPanelIdString: String { get }

    /// The id of the first terminal panel on the pinned workspace whose hosted
    /// view is the AppKit first responder, as a string, or `""` (the legacy
    /// `firstResponderPanelBefore` projection).
    var pinnedFirstResponderTerminalPanelIdString: String { get }

    /// Runs the post-`ready` resolution for the keyboard harness: installs the
    /// panel-count and workspace-alive observers, schedules the 8s timeout,
    /// optionally drives the auto-trigger (synthetic Ctrl+D or the runtime close
    /// callback), and writes every resolution capture field through the capture
    /// file at `capturePath`.
    ///
    /// This stays app-side because it owns the live Combine cancellable set, the
    /// `@Observable` workspace-list observation, the `DispatchWorkItem` timeout,
    /// and the `closePanelAfterChildExited` runtime path, all of which read and
    /// mutate live app state that cannot cross the package boundary, matching how
    /// the split-close-right visual repro stays app-side.
    func runChildExitKeyboardResolution(
        exitPanelId: UUID,
        capturePath: String,
        config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig
    )
}

/// A terminal panel's readiness as observed by a child-exit scaffold.
///
/// Carries the three booleans the legacy `waitForTerminalPanelReadyForUITest`
/// returned, plus the direct early-trigger reads, so the runner can write the
/// matching capture fields without touching live surface state.
public struct ChildExitPanelReadiness: Sendable, Equatable {
    /// Whether the terminal's hosted view is in a window (`surface.isViewInWindow`).
    public var attached: Bool

    /// Whether the terminal has a non-nil Ghostty surface (`surface.surface != nil`).
    public var hasSurface: Bool

    /// Whether the terminal's hosted view is the AppKit first responder.
    public var firstResponder: Bool

    /// Creates a readiness snapshot.
    public init(attached: Bool, hasSurface: Bool, firstResponder: Bool) {
        self.attached = attached
        self.hasSurface = hasSurface
        self.firstResponder = firstResponder
    }
}
#endif
