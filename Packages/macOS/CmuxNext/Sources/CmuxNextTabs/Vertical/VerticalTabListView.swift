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
    /// Set while a menu from the list is open (`trackMenu`).
    var menuEndObserver: (any NSObjectProtocol)?

    public init(model: TabStripModel) {
        self.model = model
        listLayout = VerticalTabListLayout(tabs: [], groups: [], showsNewTab: false, iconsOnly: false, width: 0, metrics: .current)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.expandedWidth, height: 300))
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Strings.axStrip)
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit (see PaneContentView).
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            tokenObservation?.cancel()
            hoverTimer.cancel()
            if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        }
    }

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
                for await snapshot in ObservationStream({ (VerticalTabListMetrics.current, Typography.body.pointSize) }) {
                    guard let self else { return }
                    if snapshot.0 != self.metrics { self.relayout() } else { self.needsDisplay = true }
                }
            }
        }
    }

    /// The model changed: lay the rows out again and keep the selected tab in view.
    func modelChanged() {
        relayout()
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
        listLayout = VerticalTabListLayout(tabs: model.orderedTabs, groups: model.groups, showsNewTab: model.showsNewTabButton,
                                           iconsOnly: !showsTitles, width: bounds.width, metrics: metrics)
        clampScroll()
        updateAccessibilityRows()
        needsDisplay = true
    }

    var maxScrollOffset: CGFloat { max(0, listLayout.contentHeight - bounds.height) }

    func clampScroll() {
        let clamped = min(max(0, scrollOffset), maxScrollOffset)
        if clamped != scrollOffset {
            scrollOffset = clamped
            needsDisplay = true
        }
    }

    /// Scrolls the least that shows tab `id`'s row whole.
    func reveal(_ id: TabID) {
        guard let frame = listLayout.frame(of: id) else { return }
        if frame.minY < scrollOffset {
            scrollOffset = max(0, frame.minY - metrics.verticalPadding)
        } else if frame.maxY > scrollOffset + bounds.height {
            scrollOffset = frame.maxY + metrics.verticalPadding - bounds.height
        }
        clampScroll()
        updateAccessibilityRows()
        needsDisplay = true
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

/// What the list draws from the model; a change of any of it relayouts.
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
