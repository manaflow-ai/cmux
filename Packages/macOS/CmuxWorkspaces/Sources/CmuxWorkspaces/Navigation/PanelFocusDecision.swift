public import Bonsplit

/// The pure pane/convergence decision ``PanelFocusNavigationCoordinator``
/// computes for a single `Workspace.focusPanel(_:trigger:focusIntent:)` turn,
/// returned as a value so the app-side `focusPanel` consumes it without
/// re-deriving the split-tree reads.
///
/// **What it captures (legacy `Workspace.focusPanel` locals).** `focusPanel`
/// resolves the pane that owns the target tab, decides whether the live bonsplit
/// selection has already converged onto that pane+tab, and decides whether a
/// reentrant terminal-first-responder refocus should be suppressed. Those three
/// reads are pure functions of the bonsplit split tree plus two precomputed
/// Bools, so they lift cleanly into the coordinator while every effect
/// (`focusPane`/`selectTab`/`applyTabSelection`, the `PanelFocusIntent`
/// resolution, badge/browser/layout follow-up) stays app-side.
///
/// **Why `targetHasPendingReparentSuppression` is precomputed.** It is derived
/// from the target panel's AppKit hosted view
/// (`isSuppressingReparentFocusForLayoutFollowUp()` and the layout-follow-up
/// coordinator's pending-suppression read), so the app target computes it and
/// passes it in as a `Bool`; no AppKit type crosses the seam. The decision echoes
/// it back so a consumer that needs the input value does not re-read the view.
///
/// `Sendable` because every stored field is (`PaneID` and `Bool`); the decision
/// is a value snapshot with no reference identity.
public struct PanelFocusDecision: Sendable, Equatable {
    /// The pane that currently owns the target tab, found by scanning the split
    /// tree's panes for one whose tabs contain the tab (legacy
    /// `bonsplitController.allPaneIds.first(where:)`). `nil` when no pane owns it.
    public let targetPaneId: PaneID?

    /// Whether bonsplit's focused pane already equals ``targetPaneId`` and that
    /// pane's selected tab already equals the target tab (legacy
    /// `selectionAlreadyConverged`). `false` when ``targetPaneId`` is `nil`.
    public let selectionAlreadyConverged: Bool

    /// The precomputed app-side read of whether the target terminal's hosted view
    /// has a pending reparent-focus suppression (legacy
    /// `targetHasPendingReparentSuppression`). Echoed from the input.
    public let targetHasPendingReparentSuppression: Bool

    /// Whether a reentrant refocus should be suppressed: a terminal-first-
    /// responder trigger landing on already-converged selection with a pending
    /// reparent suppression (legacy `shouldSuppressReentrantRefocus`).
    public let shouldSuppressReentrantRefocus: Bool

    public init(
        targetPaneId: PaneID?,
        selectionAlreadyConverged: Bool,
        targetHasPendingReparentSuppression: Bool,
        shouldSuppressReentrantRefocus: Bool
    ) {
        self.targetPaneId = targetPaneId
        self.selectionAlreadyConverged = selectionAlreadyConverged
        self.targetHasPendingReparentSuppression = targetHasPendingReparentSuppression
        self.shouldSuppressReentrantRefocus = shouldSuppressReentrantRefocus
    }
}
