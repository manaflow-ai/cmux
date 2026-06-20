#if DEBUG
public import Foundation

/// A pure, per-pane snapshot of the live split/close-right scaffold state for a
/// single Bonsplit pane, captured by the app-side driver on the main actor and
/// handed to ``SplitCloseRightStateCollector`` for counting and settle
/// evaluation.
///
/// The split-close-right harness builds a 2x2 grid, closes the two right panes,
/// then converges over a few main-actor turns until the remaining two panes have
/// attached, correctly-sized, non-nil terminal surfaces. Deciding whether that
/// settled state has been reached is pure value logic over a list of these
/// snapshots; only the act of *reading* the live Bonsplit / AppKit / Ghostty
/// state is app-coupled. This value type carries exactly the per-pane facts the
/// legacy `collectSplitCloseRightState` local function inspected, so the
/// counting and the settle predicate move into the package unchanged while the
/// live reads stay behind ``SplitCloseRightScaffoldDriving``.
///
/// Isolation: a `Sendable` value with no references; the driver fills one in per
/// pane and the collector folds them.
public struct SplitCloseRightPaneSnapshot: Sendable, Equatable {
    /// `true` when the pane reports a selected Bonsplit tab. A `false` value is
    /// counted as a missing-selected-tab and the pane contributes nothing else.
    public var hasSelectedTab: Bool

    /// `true` when the pane's selected tab maps to a live panel. Only meaningful
    /// when ``hasSelectedTab`` is `true`; a `false` value is counted as a
    /// missing-panel-mapping and the pane contributes nothing else.
    public var hasPanelMapping: Bool

    /// `true` when the mapped panel is a terminal panel. Non-terminal mapped
    /// panels are not counted toward the terminal tallies.
    public var isTerminal: Bool

    /// `true` when the terminal panel's surface view is in a window.
    public var isAttached: Bool

    /// `true` when the terminal panel's hosted view is smaller than 5pt in
    /// either dimension (a not-yet-laid-out pane).
    public var isZeroSize: Bool

    /// `true` when the terminal panel's underlying ghostty surface is still nil.
    public var isSurfaceNil: Bool

    /// Creates a per-pane snapshot. The defaults describe a pane with no selected
    /// tab, which the collector treats as a missing-selected-tab.
    public init(
        hasSelectedTab: Bool,
        hasPanelMapping: Bool = false,
        isTerminal: Bool = false,
        isAttached: Bool = false,
        isZeroSize: Bool = false,
        isSurfaceNil: Bool = false
    ) {
        self.hasSelectedTab = hasSelectedTab
        self.hasPanelMapping = hasPanelMapping
        self.isTerminal = isTerminal
        self.isAttached = isAttached
        self.isZeroSize = isZeroSize
        self.isSurfaceNil = isSurfaceNil
    }
}
#endif
