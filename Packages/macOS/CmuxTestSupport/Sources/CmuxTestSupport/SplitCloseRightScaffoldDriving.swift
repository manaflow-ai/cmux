#if DEBUG
public import Foundation

/// The live-action seam the split-close-right scaffold runner drives.
///
/// ``SplitCloseRightScaffoldRunner`` owns the harness *orchestration*: the
/// readiness gating, the 2x2 grid build order, closing the two right panes, the
/// settle/reconcile loop, and every capture-file write. The actual operations it
/// sequences (resolving the selected workspace, creating splits, focusing and
/// closing panes, reconciling AppKit geometry, sampling per-pane state, and the
/// CVDisplayLink-backed visual repro) read and mutate main-actor `Workspace` /
/// Bonsplit / Ghostty / `NSApp` state that cannot cross the package boundary, so
/// the app target conforms this protocol and the runner calls back through it.
///
/// Panels are identified by their `UUID` panel id, which is already the app's
/// identifier, so the runner can pass them across the seam without exposing any
/// app type. The runner never inspects a live object directly; the only data it
/// reads back are ``SplitCloseRightPaneSnapshot`` values and small scalars.
///
/// Isolation: `@MainActor`, because every operation touches main-actor terminal
/// and window state, matching the legacy bodies that ran on the main actor.
@MainActor
public protocol SplitCloseRightScaffoldDriving: AnyObject {
    /// The active workspace's id as a string, written to the `tabId` field after
    /// the grid is built (the legacy `tab.id.uuidString`).
    var workspaceIdString: String { get }

    /// Resolves the selected workspace and its initially-focused panel, awaiting
    /// terminal readiness, and reports the outcome.
    ///
    /// Returns ``SplitCloseRightSetup/ready`` with the top-left panel id when the
    /// initial terminal is attached with a non-nil surface; otherwise returns the
    /// failure case carrying the exact capture fields the legacy body wrote so
    /// the runner can persist them unchanged.
    func prepareSplitCloseRight() async -> SplitCloseRightSetup

    /// Creates a vertical (down) split from `panelId`, returning the new panel's
    /// id, or `nil` on failure (the runner writes the matching `setupError`).
    func splitDown(from panelId: UUID) -> UUID?

    /// Creates a horizontal (right) split from `panelId`, returning the new
    /// panel's id, or `nil` on failure.
    func splitRight(from panelId: UUID) -> UUID?

    /// Focuses the pane owning `panelId`.
    func focusPanel(_ panelId: UUID)

    /// Closes the pane owning `panelId` via the force-close path used by the
    /// Close Tab shortcut.
    func closePanel(_ panelId: UUID)

    /// The current Bonsplit pane count for the active workspace.
    var paneCount: Int { get }

    /// The current panel count for the active workspace.
    var panelCount: Int { get }

    /// The current total Bonsplit tab count across all panes.
    var bonsplitTabCount: Int { get }

    /// Resets the DEBUG empty-panel-appear counter before the close sequence.
    func resetEmptyPanelAppearCount()

    /// The current DEBUG empty-panel-appear count.
    var emptyPanelAppearCount: Int { get }

    /// Lays out and reconciles every visible terminal's geometry before sampling
    /// (the legacy `reconcileVisibleTerminalGeometry` local function).
    func reconcileVisibleTerminalGeometry()

    /// One ``SplitCloseRightPaneSnapshot`` per live Bonsplit pane, in pane order.
    func paneSnapshots() -> [SplitCloseRightPaneSnapshot]

    /// Runs the CVDisplayLink-backed visual repro for the configured pattern.
    ///
    /// This path owns the CVDisplayLink IOSurface-timeline capture, which the
    /// TabManager god plan keeps as sanctioned `#if DEBUG` app-target scaffolding,
    /// so the runner only forwards the already-clamped configuration and lets the
    /// app body drive and persist the timeline results.
    func runVisualRepro(
        topLeftPanelId: UUID,
        config: UITestSplitScaffoldPlan.SplitCloseRightConfig
    ) async
}

/// The outcome of ``SplitCloseRightScaffoldDriving/prepareSplitCloseRight()``.
public enum SplitCloseRightSetup: Sendable {
    /// The initial terminal is ready; carries the top-left panel id to build from
    /// and the capture fields confirming readiness (`preTerminalAttached`,
    /// `preTerminalSurfaceNil`) so the runner writes them exactly as before.
    case ready(topLeftPanelId: UUID, captureFields: [String: String])

    /// Setup could not proceed; carries the exact capture fields the legacy body
    /// wrote for the corresponding failure (missing workspace, missing focused
    /// panel, or initial terminal not ready).
    case failed(captureFields: [String: String])
}
#endif
