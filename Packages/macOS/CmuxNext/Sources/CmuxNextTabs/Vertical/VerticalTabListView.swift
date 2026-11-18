public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// A pane's tabs as a vertical list beside its content (Edge's and Chrome's vertical tabs; Leo
/// 2026-10-20). It reads the same `TabStripModel` as the horizontal strip and sends the same
/// `TabStripIntent`s, so selecting, closing, pinning, muting, groups, multi-selection, the tab menu and
/// reordering all go through the strip's paths in the App.
///
/// One view draws every row (`VerticalTabListView+Drawing`) from a pure layout
/// (`VerticalTabListLayout`) and scrolls itself. Collapsed (Collapse Tabs) it shows icons only; with
/// `expandsOnHover` a pointer resting on it widens it over the pane's content
/// (`onHoverExpansionChange`), as Chrome's auto-expanding tabs do.
public final class VerticalTabListView: NSView {
    public let model: TabStripModel
    /// Builds right-click menus: a row gives `.tab(id, selection:)`, a group header `.group(id)`, New
    /// Tab `.newTabButton`, empty space `.emptyStrip`.
    public var contextMenuProvider: TabContextMenuProvider?
    /// Kept for the hover cards' previews (not shown by the list yet).
    public weak var previewProvider: (any TabPreviewProvider)?

    /// Icons only (Collapse Tabs).
    public var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            if !isCollapsed { endHoverExpansion() }
            relayout()
        }
    }

    /// A collapsed list widens (drawn over the pane content, not pushing it) while hovered.
    public var expandsOnHover = true {
        didSet { if !expandsOnHover { endHoverExpansion() } }
    }

    /// The width the pane reserves for the list. Hover expansion never changes it.
    public var reservedWidth: CGFloat { isCollapsed ? Self.collapsedWidth : Self.expandedWidth }
    /// Width while showing titles (hover-expanded or not collapsed).
    public static var expandedWidth: CGFloat { VerticalTabTunables.expandedWidth.value }
    /// Width at rest when collapsed.
    public static var collapsedWidth: CGFloat { VerticalTabTunables.collapsedWidth.value }
    /// The list wants a frame wider than `reservedWidth` now (hover expansion), or no longer; the host
    /// lays it out again.
    public var onHoverExpansionChange: ((Bool) -> Void)?
    public private(set) var isHoverExpanded = false

    // MARK: State

    /// The rows as last laid out, in content coordinates.
    var listLayout: VerticalTabListLayout
    var metrics = VerticalTabListMetrics.current
    /// Rows above the visible top, 0...maxScrollOffset.
    var scrollOffset: CGFloat = 0
    var hovered: VerticalTabListLayout.RowKind?
    var hoveredClose: TabID?
    var hoveredAudio: TabID?
    var press: VerticalTabPress?
    var drag: VerticalTabDrag?
    private var observation: Task<Void, Never>?
    private var tokenObservation: Task<Void, Never>?
    let hoverTimer = DemandTimer(owner: "VerticalTabList.hoverExpand")
    private(set) lazy var selectionEscape = VerticalTabSelectionEscape(list: self)
    private var trackingArea: NSTrackingArea?
    var lastSelectedID: TabID?
    var accessibilityRows: [TabID: TabAccessibilityElement] = [:]
    /// The rows changed since `accessibilityRows` were made: the next accessibility client's ask makes them again.
    var accessibilityRowsAreStale = true
    /// The model as last drawn (`modelChanged` diffs the next one against it).
    var drawnSnapshot: VerticalTabModelSnapshot?
    /// The shape `listLayout` was laid out from: a model change that keeps it moves no row.
    var laidOutShape: VerticalTabListLayout.Shape?
    /// What the list's events cost, for the count tests (`VerticalTabListPasses`).
    var passes = VerticalTabListPasses()
    /// Set while a menu from the list is open (`trackMenu`): its end-of-tracking notice (``MenuTracking``).
    var menuEnd: MenuTracking?

    public init(model: TabStripModel) {
        self.model = model
        listLayout = VerticalTabListLayout(tabs: [], groups: [], showsNewTab: false, iconsOnly: false, width: 0, metrics: .current)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.expandedWidth, height: 300))
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Strings.axStrip)
        // Group headers draw their glass opaque under Reduce Transparency, a notification rather than an observed setting.
        ReduceTransparency.shared.register(repainting: self)
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    /// Titles show: not collapsed, or widened by hover.
    var showsTitles: Bool { !isCollapsed || isHoverExpanded }

    // MARK: Window and observation

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            observation?.cancel()
            tokenObservation?.cancel()
            observation = nil
            tokenObservation = nil
            selectionEscape.remove()
            endHoverExpansion()
            return
        }
        startObserving()
        relayout()
    }

    private func startObserving() {
        if observation == nil {
            let model = model
            observation = Task { [weak self] in
                for await _ in ObservationStream({ VerticalTabModelSnapshot(model) }) {
                    guard let self else { return }
                    self.modelChanged()
                }
            }
        }
        if tokenObservation == nil {
            tokenObservation = Task { [weak self] in
                // The group headers' glass settings (`GroupChipGlass`) and the no-color group look are read only
                // while drawing, so a change to either repaints here.
                for await snapshot in ObservationStream({
                    (VerticalTabListMetrics.current, Typography.body.pointSize, GroupChipGlass.current, VerticalNoColorGroupLook.tunable.value)
                }) {
                    guard let self else { return }
                    if snapshot.0 != self.metrics { self.relayout() } else { self.needsDisplay = true }
                }
            }
        }
    }

    /// The model changed: lay the rows out again when one moves, else redraw only the rows whose tab changed (its
    /// item, its selection), and keep the selected tab in view. Leo 2026-11-18: "we draw the visible area, right?"
    func modelChanged() {
        let tabs = model.orderedTabs
        if let drawn = drawnSnapshot, VerticalTabListLayout.Shape(tabs: tabs, groups: model.groups, showsNewTab: model.showsNewTabButton) == laidOutShape {
            redrawChangedRows(from: drawn, to: VerticalTabModelSnapshot(model), tabs: tabs)
        } else {
            relayout()
        }
        if model.multiSelection.isMultiple { selectionEscape.install() } else { selectionEscape.remove() }
        if model.selectedID != lastSelectedID {
            lastSelectedID = model.selectedID
            if let id = model.selectedID { reveal(id) }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        if listLayout.width != bounds.width || listLayout.iconsOnly == showsTitles { relayout() }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { relayout() } else { clampScroll() }
    }

    /// Builds the rows for the current model, width and collapse state, then redraws.
    func relayout() {
        metrics = .current
        let tabs = model.orderedTabs
        listLayout = VerticalTabListLayout(tabs: tabs, groups: model.groups, showsNewTab: model.showsNewTabButton,
                                           iconsOnly: !showsTitles, width: bounds.width, metrics: metrics)
        laidOutShape = VerticalTabListLayout.Shape(tabs: tabs, groups: model.groups, showsNewTab: model.showsNewTabButton)
        drawnSnapshot = VerticalTabModelSnapshot(model)
        passes.layouts &+= 1
        clampScroll()
        // Made again when an accessibility client next asks (`accessibilityChildren`), not for every row now.
        accessibilityRowsAreStale = true
        invalidateAll()
    }

    /// The model changed and no row moves: the layout takes the new items (`tabs`, the model's `orderedTabs`), and only
    /// the rows whose item, selection or multi-selection changed redraw (a spinner, a title, a switch redraws one or two
    /// rows, at any tab count).
    func redrawChangedRows(from drawn: VerticalTabModelSnapshot, to snapshot: VerticalTabModelSnapshot, tabs: [TabItem]) {
        drawnSnapshot = snapshot
        var changed: Set<TabID> = []
        if listLayout.tabs.count == tabs.count {
            for (old, new) in zip(listLayout.tabs, tabs) where old != new { changed.insert(new.id) }
        }
        listLayout = listLayout.withItems(tabs)
        if drawn.selectedID != snapshot.selectedID { changed.formUnion([drawn.selectedID, snapshot.selectedID].compactMap(\.self)) }
        if drawn.multiSelection != snapshot.multiSelection {
            changed.formUnion(Set(drawn.multiSelection.ids).symmetricDifference(snapshot.multiSelection.ids))
            // One selected tab more or fewer changes whether the others draw the multi-selection fill.
            if drawn.multiSelection.isMultiple != snapshot.multiSelection.isMultiple {
                changed.formUnion(drawn.multiSelection.ids)
                changed.formUnion(snapshot.multiSelection.ids)
            }
        }
        for id in changed {
            invalidate(listLayout.row(ofTab: id))
            if !accessibilityRowsAreStale, let element = accessibilityRows[id], let row = listLayout.row(ofTab: id),
               let item = listLayout.item(row) {
                configureAccessibilityRow(element, item)
            }
        }
    }

    /// Redraws the whole view (a layout, a scroll, a theme).
    func invalidateAll() {
        passes.wholeInvalidations &+= 1
        needsDisplay = true
    }

    /// Redraws `row` alone, where it shows; nothing when it is out of view.
    func invalidate(_ row: VerticalTabListLayout.Row?) {
        guard let row else { return }
        let rect = viewRect(row.frame).insetBy(dx: -1, dy: -1)
        guard rect.intersects(bounds) else { return }
        passes.rowInvalidations &+= 1
        setNeedsDisplay(rect)
    }

    /// Redraws the row of `kind`.
    func invalidate(_ kind: VerticalTabListLayout.RowKind?) {
        invalidate(kind.flatMap { listLayout.row(of: $0) })
    }

    var maxScrollOffset: CGFloat { max(0, listLayout.contentHeight - bounds.height) }

    func clampScroll() {
        let clamped = min(max(0, scrollOffset), maxScrollOffset)
        if clamped != scrollOffset {
            scrollOffset = clamped
            invalidateAll()
        }
    }

    /// Scrolls the least that shows tab `id`'s row whole.
    func reveal(_ id: TabID) {
        guard let frame = listLayout.frame(of: id) else { return }
        let before = scrollOffset
        if frame.minY < scrollOffset {
            scrollOffset = max(0, frame.minY - metrics.verticalPadding)
        } else if frame.maxY > scrollOffset + bounds.height {
            scrollOffset = frame.maxY + metrics.verticalPadding - bounds.height
        }
        clampScroll()
        // Already in view: the rows whose selection changed redraw alone (`redrawChangedRows`). The row elements read
        // their frames when asked (`TabAccessibilityElement.frameInParent`).
        if scrollOffset != before { invalidateAll() }
    }

    /// `point` in view coordinates, in content coordinates (before scrolling).
    func contentPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: point.y + scrollOffset) }

    /// A content rect in view coordinates.
    func viewRect(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: -scrollOffset) }

    // MARK: Hover expansion

    /// The pointer came to rest on a collapsed list: widen it after the delay.
    func pointerEntered() {
        guard isCollapsed, expandsOnHover, !isHoverExpanded, drag == nil else { return }
        let delay = Duration.milliseconds(Int((VerticalTabTunables.hoverExpandDelay.value * 1000).rounded()))
        hoverTimer.scheduleIfIdle(after: delay) { @MainActor [weak self] in
            self?.beginHoverExpansion()
        }
    }

    func pointerExited() {
        hoverTimer.cancel()
        // A menu or drag from the list keeps it open; their end checks the pointer again.
        guard press == nil, drag == nil else { return }
        endHoverExpansion()
    }

    func beginHoverExpansion() {
        guard isCollapsed, expandsOnHover, !isHoverExpanded, window != nil else { return }
        isHoverExpanded = true
        applyExpandedShadow()
        relayout()
        onHoverExpansionChange?(true)
    }

    func endHoverExpansion() {
        hoverTimer.cancel()
        guard isHoverExpanded else { return }
        isHoverExpanded = false
        applyExpandedShadow()
        relayout()
        onHoverExpansionChange?(false)
    }

    /// The widened list floats over the content: a shadow along its trailing edge.
    private func applyExpandedShadow() {
        guard let layer else { return }
        performWithTheme {
            layer.shadowColor = Palette.shadow.cgColor
        }
        layer.shadowOpacity = isHoverExpanded ? 0.25 : 0
        layer.shadowRadius = isHoverExpanded ? Metrics.space3 : 0
        layer.shadowOffset = .zero
    }

    /// Ends the hover expansion once the pointer is no longer over the list (after a menu or drag).
    func collapseIfPointerLeft() {
        guard isHoverExpanded, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(point) { endHoverExpansion() }
    }

    // MARK: Tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
}

/// What the vertical tab list's events cost (its `passes`), as the strip's `TabStripRowPasses`: tests read the counts
/// around a change. A row out of view costs nothing: no draw, no element, no layout of its own.
struct VerticalTabListPasses: Equatable {
    /// Rows laid out again from the model (`relayout`).
    var layouts = 0
    /// Whole-view redraws asked for (a layout, a scroll, a theme).
    var wholeInvalidations = 0
    /// One-row redraws asked for (`invalidate(_:)`).
    var rowInvalidations = 0
    /// Rows `draw(_:)` read (the binary search's range), and the ones it drew.
    var rowsVisited = 0
    var rowsDrawn = 0
    /// Row accessibility elements configured.
    var accessibilityRowsConfigured = 0
}

/// What the list draws from the model; a change of any of it is diffed (`modelChanged`).
struct VerticalTabModelSnapshot: Equatable, Sendable {
    var tabs: [TabItem]
    var groups: [TabGroupItem]
    var selectedID: TabID?
    var multiSelection: TabMultiSelection
    var showsNewTabButton: Bool

    init(_ model: TabStripModel) {
        tabs = model.tabs
        groups = model.groups
        selectedID = model.selectedID
        multiSelection = model.multiSelection
        showsNewTabButton = model.showsNewTabButton
    }
}

/// Esc ends a tab multi-selection, as in the strip (`TabSelectionEscapeMonitor`). The key goes on to
/// whatever has focus. Installed while the list has a multi-selection.
@MainActor final class VerticalTabSelectionEscape {
    private weak var list: VerticalTabListView?
    private var monitor: Any?

    init(list: VerticalTabListView) { self.list = list }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let list = self?.list, event.window === list.window, !list.isHiddenOrHasHiddenAncestor, list.drag == nil else { return event }
            list.model.clearMultiSelection()
            return event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
