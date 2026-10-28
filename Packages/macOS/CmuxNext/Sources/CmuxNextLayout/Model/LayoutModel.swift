public import Foundation
public import Observation
public import CmuxNextDesign

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
    /// Screens of the workspace, in daemon order.
    public private(set) var screens: [LayoutScreen]
    /// The screen shown. Client-local.
    public private(set) var activeScreenID: ScreenID?
    /// The focused pane. Client-local; drives the focus ring and column reveal.
    public private(set) var focusedPane: PaneID?
    /// Dims panes other than the focused one.
    public var dimsInactivePanes = false
    /// Pins the column centering mode (tests, the demo); nil follows
    /// cmux.json `layout.centerFocusedColumn` through `DesignSettings`.
    public var centerFocusedColumnOverride: CenterFocusedColumn?
    /// Pins the width of new columns (tests, the demo); nil follows cmux.json
    /// `layout.defaultColumnWidth` (see `defaultColumnWidth`).
    public var defaultColumnWidthOverride: Double?
    /// Pins `layout.newColumnWidth` (tests, the demo).
    public var newColumnWidthModeOverride: NewColumnWidthMode?
    /// Pins `layout.splitSizing` (tests, the demo).
    public var splitSizingOverride: SplitSizing?
    /// Pins the strip scrollbar mode (tests, the demo); nil follows
    /// cmux.json `layout.stripScrollbar`.
    public var stripScrollbarOverride: StripScrollbarMode?
    /// The daemon serves edge-docks-v1: drops on a screen's top or bottom
    /// edge band open a dock (DropZoneGeometry.dockTarget).
    public var acceptsEdgeDockDrops = false
    /// The daemon serves `rows-v1`: row heights and new rows may be sent.
    /// Without it no row op leaves the model (plans/cmux-next/rows.md).
    public var acceptsRowOps = false
    /// Pins `layout.rows` (tests, the demo); nil follows cmux.json.
    public var rowsEnabledOverride: Bool?
    /// Pins `layout.focusFollowsMouse` (tests, the demo); nil follows cmux.json.
    public var focusFollowsMouseOverride: Bool?
    /// Hovering or scrolling over a pane focuses it (cmux.json `layout.focusFollowsMouse`):
    /// the override, else the live setting while `followsDesignMetrics` is on, else off.
    public var focusFollowsMouse: Bool {
        focusFollowsMouseOverride ?? (followsDesignMetrics ? DesignSettings.shared.focusFollowsMouse : false)
    }
    /// Pins `layout.scrollModifier` (tests, the demo); nil follows cmux.json.
    public var scrollModifierOverride: LayoutScrollModifier?
    /// Which scroll moves the layout (cmux.json `layout.scrollModifier`, `LayoutRootView+Scroll`):
    /// the override, else the live setting while `followsDesignMetrics` is on, else `.command`.
    public var scrollModifier: LayoutScrollModifier {
        scrollModifierOverride ?? (followsDesignMetrics ? DesignSettings.shared.layoutScrollModifier : .command)
    }
    /// Column centering mode: the override, else the live setting
    /// while `followsDesignMetrics` is on, else `.never`.
    public var centerFocusedColumn: CenterFocusedColumn {
        centerFocusedColumnOverride ?? (followsDesignMetrics ? DesignSettings.shared.centerFocusedColumn : .never)
    }
    /// What moved the focus last; the column scroll never centers a click.
    @ObservationIgnored public private(set) var lastFocusSource: ColumnFocusSource = .programmatic
    /// Layout knobs that are not design tokens (minimum pane extent, drop
    /// zones, dimming). Its token fields are ignored while
    /// `followsDesignMetrics` is on.
    public var baseStyle = LayoutStyle()
    /// Takes column gap, divider, and corner radius from the live `Metrics`
    /// (density and cmux.json overrides). Turn off to pin `baseStyle` exactly.
    public var followsDesignMetrics = true
    /// The resolved style the views lay out with. Observation-tracked on both
    /// this model and the design settings it reads, so a density or metric
    /// override change relayouts every screen live.
    ///
    /// Resolved once per settings change, not per read (I7): the views read
    /// it many times per frame, and `applyingDesignMetrics` reads about 30
    /// settings. The cache keys on this model's inputs; a change of any
    /// design setting it read drops it (`designStyleDidChange`).
    public var style: LayoutStyle {
        let key = StyleKey(base: baseStyle, follows: followsDesignMetrics, rows: rowsEnabledOverride)
        guard followsDesignMetrics else { return key.resolved(design: baseStyle) }
        _ = designStyleGeneration
        if let cachedStyle, cachedStyle.key == key { return cachedStyle.value }
        let design: LayoutStyle
        if styleTrackingArmed {
            // A tracking is live: it already watches every setting this reads.
            design = baseStyle.applyingDesignMetrics()
        } else {
            styleTrackingArmed = true
            design = withObservationTracking {
                baseStyle.applyingDesignMetrics()
            } onChange: { [weak self] in
                // A will-set: the new value is not stored yet. Drop the cache
                // at once (a read after the write resolves again), and once
                // more after the write, with the bump that wakes the views (a
                // read between the will-set and the write cached the old value).
                if Thread.isMainThread { MainActor.assumeIsolated { self?.cachedStyle = nil } } // main-proof: checked on this line
                Task { @MainActor in self?.designStyleDidChange() }
            }
        }
        let value = key.resolved(design: design)
        cachedStyle = (key, value)
        return value
    }

    private struct StyleKey: Equatable {
        var base: LayoutStyle
        var follows: Bool
        var rows: Bool?
        func resolved(design: LayoutStyle) -> LayoutStyle {
            var style = design
            if let rows { style.rowsEnabled = rows }
            return style
        }
    }

    @ObservationIgnored private var cachedStyle: (key: StyleKey, value: LayoutStyle)?
    /// Bumped when a design setting `style` read changed: readers of
    /// `style` observe it.
    private var designStyleGeneration = 0

    /// One tracking of the design settings is live at a time.
    @ObservationIgnored private var styleTrackingArmed = false

    private func designStyleDidChange() {
        styleTrackingArmed = false
        cachedStyle = nil
        designStyleGeneration &+= 1
    }

    /// Panes that need attention (an unread notification), with the mark
    /// the overlay draws. Set by the App from daemon unread state.
    public var attention: [PaneID: AttentionMark] = [:]
    /// Panes whose mark the last `attention` change removed because the person
    /// went into the pane (a click, a key, an open): their ring blinks out, as
    /// cmux classic's dismiss flash did. Set by the App just before `attention`.
    public var attentionReadByEntry: Set<PaneID> = []

    /// Panes whose frame currently intersects the visible viewport of the
    /// active screen. Hosted views stay alive while not visible; use this to
    /// pause rendering or release attach geometry for occluded panes.
    public private(set) var visiblePanes: Set<PaneID> = []

    /// `visiblePanes` plus panes within one viewport width of the viewport
    /// on the active screen (architecture.md 4). Keep their content alive
    /// (paused) so scrolling back shows it with no blank frames; release
    /// content of panes outside this set like hidden tabs.
    public private(set) var keepAlivePanes: Set<PaneID> = []

    /// True while a divider or column drag is in progress.
    public private(set) var isGestureActive = false

    /// The latest one-shot "center this column" request. The view scrolls the column to the viewport center
    /// once per request; `sequence` distinguishes repeats of the same pane.
    public private(set) var centerRequest: ColumnCenterRequest?

    /// The latest one-shot "show this column" request (``revealColumn(containing:)``). The view applies it
    /// once the pane's column is in the strip, which may be a later snapshot than the request's.
    public private(set) var revealRequest: ColumnCenterRequest?

    /// Screens shown as a canvas, by screen (plans/cmux-next/canvas-layout.md). Client-local, like
    /// the strip scroll: the daemon keeps the screen's tree, and this its free-placed presentation.
    public internal(set) var canvases: [ScreenID: CanvasScreen] = [:]
    /// Each canvas screen's viewport, reported by its view: fitting and revealing read it.
    @ObservationIgnored var canvasViewports: [ScreenID: CGSize] = [:]

    /// Receives every intent. Set by the App (or `MockLayoutSource`).
    @ObservationIgnored public var intentHandler: (@MainActor (LayoutIntent) -> Void)?

    @ObservationIgnored var splitOverrides: [SplitID: Override] = [:]
    /// Panes a pending close hides from the shown screens (`showPaneClose`).
    @ObservationIgnored var paneCloses: [PaneID: PaneCloseHold] = [:]
    /// The last pending close's order (`PaneCloseHold.sequence`).
    @ObservationIgnored var paneCloseSequence = 0
    /// Fit-screen widths of shown column closes that landed while another close on their screen was
    /// pending, not sent yet (`flushLandedCloseSizes`).
    @ObservationIgnored var landedCloseWidths: [ColumnID: Double] = [:]
    /// Even ratios of shown closes that landed while another close on their screen was pending, not
    /// sent yet (`flushLandedCloseSizes`).
    @ObservationIgnored var landedCloseRatios: [SplitID: Double] = [:]
    /// Until this uptime, a ratio-only change is an explicit equalize the screens spring (Lawrence 2026-10-16).
    @ObservationIgnored public private(set) var explicitReflowUntil: TimeInterval = 0
    static let explicitReflowWindow: TimeInterval = 0.6
    /// An explicit equalize is in its window now.
    public var animatesReflow: Bool { ProcessInfo.processInfo.systemUptime < explicitReflowUntil }
    @ObservationIgnored var widthOverrides: [ColumnID: Override] = [:]
    /// A pane whose shown content the next structural change moves into the pane it adds, until an
    /// uptime (`handOffContent(of:)`).
    @ObservationIgnored var contentHandoff: (pane: PaneID, until: TimeInterval)?
    static let contentHandoffWindow: TimeInterval = 3


    struct Override {
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
    @ObservationIgnored private(set) var daemonScreens: [LayoutScreen] = []

    public init(screens: [LayoutScreen] = [], activeScreenID: ScreenID? = nil, focusedPane: PaneID? = nil) {
        self.screens = screens
        daemonScreens = screens
        self.activeScreenID = activeScreenID ?? screens.first?.id
        self.focusedPane = focusedPane ?? screens.first?.layout.panes.first
    }

    // MARK: Daemon input

    /// Replaces the tree with a daemon snapshot. Keeps client-local focus and
    /// active screen when they still exist. A closed focused pane falls back to
    /// its nearest surviving neighbor before it (else after it, else the first).
    public func apply(screens newScreens: [LayoutScreen]) {
        let previous = daemonScreens
        // Shown closes whose pane leaves the daemon's tree now: their column widths are reconciled
        // across the closes still pending (`noteLandedColumnClose`), not taken from the raw trees.
        let landed = Set(paneCloses.keys.filter { pane in !newScreens.contains { $0.layout.contains(pane) } })
        noteLandedCloses(from: previous, to: newScreens, landed: landed) // before the overlay below reads them
        defer {
            applyCloseSizing(from: previous, to: newScreens, landed: landed)
            flushLandedCloseSizes()
        }
        daemonScreens = newScreens
        resolvePaneCloses(in: newScreens)
        splitOverrides = splitOverrides.filter { !$0.value.settled }
        widthOverrides = widthOverrides.filter { !$0.value.settled }
        // Equal screens (the echo of this client's own gesture, a snapshot
        // that changed another workspace) write nothing, so no observer runs.
        let next = overlaid(newScreens)
        if next != screens { screens = next }
        reconcileCanvases()
        if activeScreenID == nil || !screens.contains(where: { $0.id == activeScreenID }) {
            activeScreenID = screens.first?.id
        }
        if let focusedPane, screens.contains(where: { $0.layout.contains(focusedPane) }) {
            return
        }
        // The focused pane closed. The app's focus coordinator picks the successor right after
        // (close-focus.md); until then the nearest surviving pane before it (after it at the
        // start) stands in, not the screen's first: the close's first frame already moves the
        // camera toward it (Lawrence 2026-10-20, closing the last column).
        let fallback = focusedPane.flatMap { Self.neighbor(of: $0, in: previous, on: activeScreen) } ?? activeScreen?.layout.panes.first
        if focusedPane != fallback { focusedPane = fallback }
    }

    /// The pane of `screen` nearest before `closed` in its old order (`old`), else the nearest
    /// after it; nil when the old screen did not hold it.
    private static func neighbor(of closed: PaneID, in old: [LayoutScreen], on screen: LayoutScreen?) -> PaneID? {
        guard let screen, let order = old.first(where: { $0.id == screen.id })?.layout.panes,
              let index = order.firstIndex(of: closed) else { return nil }
        let live = Set(screen.layout.panes)
        return order[..<index].last(where: live.contains) ?? order[(index + 1)...].first(where: live.contains)
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
        showOverlaid()
    }

    /// Shows the last daemon snapshot with every local override and pending close on it.
    func showOverlaid() {
        let shown = overlaid(daemonScreens)
        if shown != screens { screens = shown }
        reconcileCanvases() // a canvas draws its own frames: a pane a close hid leaves it now
    }

    /// Applies live and unconfirmed overrides onto daemon screens. An ended
    /// override whose value the daemon already reports is confirmed and dropped.
    /// A pending pane close (`showPaneClose`) takes its pane out first.
    private func overlaid(_ source: [LayoutScreen]) -> [LayoutScreen] {
        var result = source
        for index in result.indices {
            var layout = result[index].layout
            layout = overlayingPaneCloses(layout)
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

    /// Focuses `pane` from `source` (a click, a scroll) and emits the intent.
    public func focus(_ pane: PaneID, source: ColumnFocusSource) {
        focus(pane, notify: true, source: source)
    }

    /// Focuses `pane`. `notify: false` mirrors a focus decided elsewhere
    /// (the app's focus coordinator) without emitting an intent.
    public func focus(_ pane: PaneID, notify: Bool, source: ColumnFocusSource = .programmatic) {
        guard let screen = screen(containing: pane) else { return }
        if activeScreenID != screen.id { activeScreenID = screen.id }
        if focusedPane == pane {
            // A pointer or scroll can re-focus the already active pane. Keep the source current
            // so a keyboard ring is dismissed immediately, without letting passive programmatic
            // reveals overwrite that pointer state.
            if source == .pointer || source == .scroll { lastFocusSource = source }
            return
        }
        lastFocusSource = source
        focusedPane = pane
        // A keyboard or programmatic focus on a canvas pans to it; a click or a scroll never does.
        if source != .pointer, source != .scroll { revealOnCanvas(pane, screen: screen.id) }
        if notify { emit(.focus(pane)) }
    }

    /// Moves focus to the neighboring pane in `direction` on the active screen.
    /// `frames` are content-space pane frames; the view supplies them via
    /// `LayoutRootView.moveFocus(_:)`. Returns the newly focused pane.
    @discardableResult
    public func moveFocus(_ direction: LayoutDirection, frames: [PaneID: CGRect]) -> PaneID? {
        guard let focusedPane, let next = FocusNavigation.neighbor(of: focusedPane, direction: direction, frames: frames) else { return nil }
        focus(next, notify: true, source: .keyboard)
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

    /// Scrolls the column holding `pane` (default: the focused pane) to the
    /// center of the viewport and focuses that pane. Client-local: scroll offsets are never sent to the
    /// daemon. Returns false when the pane is not in a columns screen.
    @discardableResult
    public func centerColumn(containing pane: PaneID? = nil) -> Bool {
        guard let pane = pane ?? focusedPane, screen(containing: pane)?.layout.column(containing: pane) != nil else { return false }
        focus(pane)
        centerRequest = ColumnCenterRequest(pane: pane, sequence: (centerRequest?.sequence ?? 0) &+ 1)
        return true
    }

    /// Scrolls the column holding `pane` into view, the least that shows it, and leaves focus where it
    /// is: a tab opened beside a chat that keeps focus (cx-27j7). The strip otherwise follows focus
    /// only, so a column added out of view would stay there. Client-local, like ``centerColumn(containing:)``.
    public func revealColumn(containing pane: PaneID) {
        revealRequest = ColumnCenterRequest(pane: pane, sequence: (revealRequest?.sequence ?? 0) &+ 1)
    }

    // MARK: Divider and column gestures

    /// Sets a divider ratio locally. Only the `.ended` value is reported (one
    /// daemon command per drag): a live value moves the layout here and
    /// nowhere else, so a drag costs the daemon nothing until it ends.
    public func setSplitRatio(_ split: SplitID, ratio: Double, transaction: LayoutTransactionID, phase: LayoutGesturePhase) {
        let ratio = min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
        updateScreen(where: { $0.ratio(of: split) != nil }) { $0.settingRatio(ratio, for: split) }
        splitOverrides[split] = Override(value: ratio, transaction: transaction, ended: phase == .ended)
        if phase == .ended { emit(.setSplitRatio(split, ratio: ratio, transaction: transaction, phase: phase)) }
    }

    /// Equalizes `split` so every cell in its same-axis chain gets equal size. An explicit
    /// equalize springs (`explicitReflowUntil`); the sizing that follows a split or a close moves
    /// with that gesture instead.
    public func equalizeSplit(_ split: SplitID) {
        guard let tree = screens.lazy.compactMap({ $0.layout.tree(containing: split) }).first,
              let ratio = tree.equalizedRatio(for: split) else { return }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        setSplitRatio(split, ratio: ratio, transaction: .make(), phase: .ended)
    }

    /// Drops the sent (ended) ratio overrides of `splits`: a newer change owns their ratios now. A
    /// live gesture's or a pending split's override stays.
    func supersedeSentRatios(_ splits: Set<SplitID>) {
        guard !splits.isEmpty else { return }
        splitOverrides = splitOverrides.filter { !splits.contains($0.key) || !$0.value.ended }
    }

    /// Drops the sent (ended) width overrides of `columns`: a newer change owns their widths now. A
    /// live gesture's override stays.
    func supersedeSentWidths(_ columns: Set<ColumnID>) {
        guard !columns.isEmpty else { return }
        widthOverrides = widthOverrides.filter { !columns.contains($0.key) || !$0.value.ended }
    }

    /// Sets a column width locally; reports only the `.ended` value, like `setSplitRatio`.
    public func setColumnWidth(_ column: ColumnID, width: Double, transaction: LayoutTransactionID, phase: LayoutGesturePhase) {
        let width = min(max(width, ColumnWidthPreset.widthRange.lowerBound), ColumnWidthPreset.widthRange.upperBound)
        guard let anyPane = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else { return }
        updateScreen(where: { layout in layout.columns.contains { $0.id == column } }) { $0.settingWidth(width, for: column) }
        widthOverrides[column] = Override(value: width, transaction: transaction, ended: phase == .ended)
        if phase == .ended { emit(.setColumnWidth(column, anyPane: anyPane, width: width, transaction: transaction, phase: phase)) }
    }

    /// Marks the start and end of a pointer gesture so views skip animation
    /// while the pointer drives the layout.
    public func setGestureActive(_ active: Bool) {
        if isGestureActive != active { isGestureActive = active }
    }

    /// Cancels a pointer gesture that will get no release (its divider or
    /// column went away mid-drag): its overrides drop, the last daemon
    /// values show, and `.cancelGesture` tells the App. Nothing of the
    /// gesture reached the daemon (live values are local).
    public func cancelGesture(_ transaction: LayoutTransactionID) {
        rejectTransaction(transaction)
        emit(.cancelGesture(transaction))
    }

    /// Rewrites the one screen whose layout matches `owns` (a split or a
    /// column belongs to one screen): a drag frame touches only the screen
    /// it drags, and writes nothing when the value is already in place.
    func updateScreen(where owns: (ScreenLayout) -> Bool, _ transform: (ScreenLayout) -> ScreenLayout) {
        guard let index = screens.firstIndex(where: { owns($0.layout) }) else { return }
        let layout = transform(screens[index].layout)
        if layout != screens[index].layout { screens[index].layout = layout }
    }

    // MARK: Structure

    public func dropTab(_ tab: TabID, on target: DropTarget) {
        emit(.dropTab(tab, target))
    }

    public func reportScroll(screen: ScreenID, leadingColumn: ColumnID) {
        emit(.scrollTo(screen, column: leadingColumn))
    }

    // MARK: View reports

    /// Called by the view when pane visibility changes. `keepAlive`
    /// includes the visible panes.
    public func reportVisiblePanes(_ panes: Set<PaneID>, keepAlive: Set<PaneID>) {
        if visiblePanes != panes { visiblePanes = panes }
        let keepAlive = keepAlive.union(panes)
        if keepAlivePanes != keepAlive { keepAlivePanes = keepAlive }
    }

    func emit(_ intent: LayoutIntent) {
        intentHandler?(intent)
    }
}
