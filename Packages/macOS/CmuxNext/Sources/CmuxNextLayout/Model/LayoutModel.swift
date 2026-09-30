public import Foundation
public import Observation

/// Input and output of the layout engine for one workspace.
///
/// The App mirrors daemon state into it with `apply(screens:)` and handles
/// `LayoutIntent`s from `intentHandler`. Local gestures update the tree
/// optimistically so drags track the pointer before the daemon echoes them.
/// Each gesture carries a `LayoutTransactionID`; its local value overrides
/// incoming snapshots until the App settles the transaction (the daemon
/// accepted the command, so the next snapshot wins) or rejects it (the last
/// daemon value is restored at once). No snapshot-counting heuristics.
@Observable
@MainActor
public final class LayoutModel {
    /// Screens of the workspace, in switcher order.
    public private(set) var screens: [LayoutScreen]
    /// The screen shown. Client-local.
    public private(set) var activeScreenID: ScreenID?
    /// The focused pane. Client-local; drives the focus ring and column reveal.
    public private(set) var focusedPane: PaneID?
    /// Shows the screen switcher chrome. Off by default (REWRITE.md goal 5).
    public var showsScreenSwitcher = false
    /// Dims panes other than the focused one.
    public var dimsInactivePanes = false
    /// How focus changes scroll columns into view.
    public var columnRevealMode: ColumnRevealMode = .minimal
    /// Layout knobs that are not design tokens (minimum pane extent, drop
    /// zones, dimming). Its token fields are ignored while
    /// `followsDesignMetrics` is on.
    public var baseStyle = LayoutStyle()
    /// Takes column gap, divider, and corner radius from the live `Metrics`
    /// (density and cmux.json overrides). Turn off to pin `baseStyle` exactly.
    public var followsDesignMetrics = true
    /// The resolved style the views lay out with. Observation-tracked on both
    /// this model and `DesignSettings.shared`, so a density or metric override
    /// change relayouts every screen live.
    public var style: LayoutStyle {
        followsDesignMetrics ? baseStyle.applyingDesignMetrics() : baseStyle
    }

    /// Panes whose frame currently intersects the visible viewport of the
    /// active screen. Hosted views stay alive while not visible; use this to
    /// pause rendering or release attach geometry for occluded panes.
    public private(set) var visiblePanes: Set<PaneID> = []

    /// True while a divider or column drag is in progress.
    public private(set) var isGestureActive = false

    /// The latest one-shot "center this column" request (niri
    /// `center-column`). The view scrolls the column to the viewport center
    /// once per request; `sequence` distinguishes repeats of the same pane.
    public private(set) var centerRequest: ColumnCenterRequest?

    /// Receives every intent. Set by the App (or `MockLayoutSource`).
    @ObservationIgnored public var intentHandler: (@MainActor (LayoutIntent) -> Void)?

    @ObservationIgnored private var pendingIntents: [PendingKey: LayoutIntent] = [:]
    @ObservationIgnored private var splitOverrides: [SplitID: Override] = [:]
    @ObservationIgnored private var widthOverrides: [ColumnID: Override] = [:]

    private enum PendingKey: Hashable {
        case split(SplitID)
        case column(ColumnID)
    }

    private struct Override {
        var value: Double
        var transaction: LayoutTransactionID
        var ended = false
        /// The daemon accepted the gesture's final command: the next snapshot
        /// is authoritative (it was requested after the command committed on
        /// the same serial connection), so the override yields to it.
        var settled = false
    }

    /// The last daemon snapshot, without local overrides. Restored when a
    /// transaction is rejected.
    @ObservationIgnored private var daemonScreens: [LayoutScreen] = []

    public init(screens: [LayoutScreen] = [], activeScreenID: ScreenID? = nil, focusedPane: PaneID? = nil) {
        self.screens = screens
        daemonScreens = screens
        self.activeScreenID = activeScreenID ?? screens.first?.id
        self.focusedPane = focusedPane ?? screens.first?.layout.panes.first
    }

    // MARK: Daemon input

    /// Replaces the tree with a daemon snapshot. Keeps client-local focus and
    /// active screen when they still exist, else falls back to the first.
    public func apply(screens newScreens: [LayoutScreen]) {
        daemonScreens = newScreens
        splitOverrides = splitOverrides.filter { !$0.value.settled }
        widthOverrides = widthOverrides.filter { !$0.value.settled }
        screens = overlaid(newScreens)
        if activeScreenID == nil || !screens.contains(where: { $0.id == activeScreenID }) {
            activeScreenID = screens.first?.id
        }
        if let focusedPane, screens.contains(where: { $0.layout.contains(focusedPane) }) {
            return
        }
        focusedPane = activeScreen?.layout.panes.first
    }

    /// The daemon accepted the command carrying `transaction`. An ended
    /// gesture's override is dropped at the next snapshot; a live gesture
    /// keeps tracking the pointer.
    public func settleTransaction(_ transaction: LayoutTransactionID) {
        for (key, value) in splitOverrides where value.transaction == transaction && value.ended {
            splitOverrides[key]?.settled = true
        }
        for (key, value) in widthOverrides where value.transaction == transaction && value.ended {
            widthOverrides[key]?.settled = true
        }
    }

    /// The daemon rejected the command carrying `transaction`: drop its
    /// overrides and show the last daemon value at once.
    public func rejectTransaction(_ transaction: LayoutTransactionID) {
        let splits = splitOverrides.count, widths = widthOverrides.count
        splitOverrides = splitOverrides.filter { $0.value.transaction != transaction }
        widthOverrides = widthOverrides.filter { $0.value.transaction != transaction }
        guard splits != splitOverrides.count || widths != widthOverrides.count else { return }
        let restored = overlaid(daemonScreens)
        if restored != screens { screens = restored }
    }

    /// Applies live and unconfirmed overrides onto daemon screens. An ended
    /// override whose value the daemon already reports is confirmed and dropped.
    private func overlaid(_ source: [LayoutScreen]) -> [LayoutScreen] {
        var result = source
        for index in result.indices {
            var layout = result[index].layout
            for (split, override) in splitOverrides {
                guard let incoming = layout.ratio(of: split) else { continue }
                if abs(incoming - override.value) < 0.002 {
                    if override.ended { splitOverrides[split] = nil }
                } else {
                    layout = layout.settingRatio(override.value, for: split)
                }
            }
            for (column, override) in widthOverrides {
                guard let incoming = layout.columns.first(where: { $0.id == column })?.width else { continue }
                if abs(incoming - override.value) < 0.002 {
                    if override.ended { widthOverrides[column] = nil }
                } else {
                    layout = layout.settingWidth(override.value, for: column)
                }
            }
            result[index].layout = layout
        }
        return result
    }

    // MARK: Queries

    public var activeScreen: LayoutScreen? {
        screens.first { $0.id == activeScreenID }
    }

    public func screen(containing pane: PaneID) -> LayoutScreen? {
        screens.first { $0.layout.contains(pane) }
    }

    // MARK: Focus and screens

    /// Focuses `pane` (client-local) and reports `.focus`.
    public func focus(_ pane: PaneID) {
        focus(pane, notify: true)
    }

    /// Focuses `pane`. `notify: false` mirrors a focus decided elsewhere
    /// (the app's focus coordinator) without emitting an intent.
    public func focus(_ pane: PaneID, notify: Bool) {
        guard let screen = screen(containing: pane) else { return }
        if activeScreenID != screen.id { activeScreenID = screen.id }
        guard focusedPane != pane else { return }
        focusedPane = pane
        if notify { emit(.focus(pane)) }
    }

    /// Moves focus to the neighboring pane in `direction` on the active screen.
    /// `frames` are content-space pane frames; the view supplies them via
    /// `LayoutRootView.moveFocus(_:)`. Returns the newly focused pane.
    @discardableResult
    public func moveFocus(_ direction: LayoutDirection, frames: [PaneID: CGRect]) -> PaneID? {
        guard let focusedPane, let next = FocusNavigation.neighbor(of: focusedPane, direction: direction, frames: frames) else { return nil }
        focus(next)
        return next
    }

    public func selectScreen(_ id: ScreenID) {
        guard activeScreenID != id, let screen = screens.first(where: { $0.id == id }) else { return }
        activeScreenID = id
        if focusedPane.map({ !screen.layout.contains($0) }) ?? true {
            focusedPane = screen.layout.panes.first
        }
        emit(.selectScreen(id))
    }

    /// Selects the next (or previous) screen, wrapping.
    public func selectAdjacentScreen(forward: Bool) {
        guard let index = screens.firstIndex(where: { $0.id == activeScreenID }), screens.count > 1 else { return }
        let next = (index + (forward ? 1 : -1) + screens.count) % screens.count
        selectScreen(screens[next].id)
    }

    /// Scrolls the column holding `pane` (default: the focused pane) to the
    /// center of the viewport and focuses that pane, like niri's
    /// `center-column`. Client-local: scroll offsets are never sent to the
    /// daemon. Returns false when the pane is not in a columns screen.
    @discardableResult
    public func centerColumn(containing pane: PaneID? = nil) -> Bool {
        guard let pane = pane ?? focusedPane, screen(containing: pane)?.layout.column(containing: pane) != nil else { return false }
        focus(pane)
        centerRequest = ColumnCenterRequest(pane: pane, sequence: (centerRequest?.sequence ?? 0) &+ 1)
        return true
    }

    // MARK: Divider and column gestures

    /// Sets a divider ratio locally and reports it. `.changed` intents are
    /// coalesced until `flushPendingGestureIntents()` (called once per display
    /// frame by the view); `.ended` flushes immediately.
    public func setSplitRatio(_ split: SplitID, ratio: Double, transaction: LayoutTransactionID, phase: LayoutGesturePhase) {
        let ratio = min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
        updateScreens { $0.settingRatio(ratio, for: split) }
        splitOverrides[split] = Override(value: ratio, transaction: transaction, ended: phase == .ended)
        let intent = LayoutIntent.setSplitRatio(split, ratio: ratio, transaction: transaction, phase: phase)
        record(intent, key: .split(split), phase: phase)
    }

    /// Equalizes `split` so every cell in its same-axis chain gets equal size.
    public func equalizeSplit(_ split: SplitID) {
        guard let tree = screens.lazy.compactMap({ $0.layout.tree(containing: split) }).first,
              let ratio = tree.equalizedRatio(for: split) else { return }
        setSplitRatio(split, ratio: ratio, transaction: .make(), phase: .ended)
    }

    /// Sets a column width locally and reports it. Same throttling as `setSplitRatio`.
    public func setColumnWidth(_ column: ColumnID, width: Double, transaction: LayoutTransactionID, phase: LayoutGesturePhase) {
        let width = min(max(width, ColumnWidthPreset.widthRange.lowerBound), ColumnWidthPreset.widthRange.upperBound)
        guard let anyPane = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else { return }
        updateScreens { $0.settingWidth(width, for: column) }
        widthOverrides[column] = Override(value: width, transaction: transaction, ended: phase == .ended)
        let intent = LayoutIntent.setColumnWidth(column, anyPane: anyPane, width: width, transaction: transaction, phase: phase)
        record(intent, key: .column(column), phase: phase)
    }

    /// Cycles the focused pane's column through the width presets.
    public func cycleColumnWidthPreset(forward: Bool = true) {
        guard let focusedPane, let column = screen(containing: focusedPane)?.layout.column(containing: focusedPane) else { return }
        let preset = ColumnWidthPreset.next(after: column.width, forward: forward)
        setColumnWidth(column.id, width: preset.rawValue, transaction: .make(), phase: .ended)
    }

    /// Sets the focused pane's column to `preset`.
    public func setFocusedColumnWidth(_ preset: ColumnWidthPreset) {
        guard let focusedPane, let column = screen(containing: focusedPane)?.layout.column(containing: focusedPane) else { return }
        setColumnWidth(column.id, width: preset.rawValue, transaction: .make(), phase: .ended)
    }

    /// Marks the start and end of a pointer gesture so views skip animation
    /// while the pointer drives the layout.
    public func setGestureActive(_ active: Bool) {
        if isGestureActive != active { isGestureActive = active }
    }

    /// Emits the latest coalesced `.changed` intent per divider or column.
    public func flushPendingGestureIntents() {
        guard !pendingIntents.isEmpty else { return }
        let intents = pendingIntents.values
        pendingIntents.removeAll()
        for intent in intents { emit(intent) }
    }

    public var hasPendingGestureIntents: Bool { !pendingIntents.isEmpty }

    private func record(_ intent: LayoutIntent, key: PendingKey, phase: LayoutGesturePhase) {
        switch phase {
        case .changed:
            pendingIntents[key] = intent
        case .ended:
            pendingIntents[key] = nil
            emit(intent)
        }
    }

    private func updateScreens(_ transform: (ScreenLayout) -> ScreenLayout) {
        var next = screens
        for index in next.indices {
            next[index].layout = transform(next[index].layout)
        }
        if next != screens { screens = next }
    }

    // MARK: Structure

    /// Requests a new column after the focused pane's column (niri-style).
    public func newColumn(width: Double = ColumnWidthPreset.defaultWidth) {
        guard let focusedPane else { return }
        emit(.newColumn(after: focusedPane, width: width))
    }

    /// Requests a split of the focused pane.
    public func splitFocusedPane(axis: SplitAxis) {
        guard let focusedPane else { return }
        emit(.split(focusedPane, axis: axis))
    }

    public func dropTab(_ tab: TabID, on target: DropTarget) {
        emit(.dropTab(tab, target))
    }

    public func reportScroll(screen: ScreenID, leadingColumn: ColumnID) {
        emit(.scrollTo(screen, column: leadingColumn))
    }

    // MARK: View reports

    /// Called by the view when pane visibility changes.
    public func reportVisiblePanes(_ panes: Set<PaneID>) {
        if visiblePanes != panes { visiblePanes = panes }
    }

    private func emit(_ intent: LayoutIntent) {
        intentHandler?(intent)
    }
}
