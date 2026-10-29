public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextWakeups
import Observation
import QuartzCore

/// The tab strip for one pane.
///
/// Reads a `TabStripModel`, lays tabs out with `TabLayoutEngine`, and animates
/// between layouts with per-tab springs on a display link, so open, close,
/// reorder, and scroll all retarget smoothly mid-flight. All user actions go
/// out as `TabStripIntent`s through `model.send`; the strip never edits the
/// model itself.
public final class TabStripView: NSView {
    public enum Background: Sendable {
        case none
        /// One Liquid Glass panel behind all tabs.
        case glass
    }

    /// Height the strip is designed for (density token).
    public static var preferredHeight: CGFloat { Metrics.tabStripHeight }

    public let model: TabStripModel
    let inputTap: InputEventTap  // the app's one; the strip's modes subscribe only while they last
    /// The app's one deadline placer: the strip's holds, the reorder settle and closing mode's exit are deadlines on it,
    /// and its ``MainDeadlineScheduler/work`` runs the strip's observations.
    let deadlines: MainDeadlineScheduler
    /// The strip in the visibility tree (recipe R-hide): under the node it shows under (its pane's or its bar's),
    /// own-hidden while AppKit hides the strip or an ancestor (`viewDidHide`). A model, appearance or scale change
    /// that comes while it is not visible waits on it (`deferUntilVisible`) and applies once, at rest, in its show
    /// turn; the plus's settings observation tracks only while it is visible (``TabStripRevealController``).
    public let visibilityNode: VisibilityNode
    /// The strip's own hover moves (`pointerFrameHover`, `TabStripView+Pointer`) on the window's frame input
    /// coalescer: two strips never merge theirs.
    private(set) lazy var frameInputHover = PointerFrameHover(owner: "TabStripView.hover", view: self) { [weak self] point in self?.hoverMoved(toWindowPoint: point) }
    /// A running tab or group drag's moves (`pointerFrameDrags`, `TabStripView+Drag`): once per frame; the lift and the tear-off act on their own event.
    private(set) lazy var dragMoves = PointerFrameDrag(owner: "TabStripView.drag", view: self) { [weak self] point in self?.dragMoved(toWindowPoint: point) }

    public weak var previewProvider: (any TabPreviewProvider)? {
        didSet { hoverCard.previewProvider = previewProvider }
    }

    /// Fixed metrics instead of the live design tokens. Nil (the default)
    /// follows `DesignSettings.shared`: density and per-metric overrides
    /// apply live, with a relayout and re-measured titles.
    public var customMetrics: TabStripMetrics? {
        didSet { applyTokens(animated: false) }
    }

    /// Metrics in effect. Re-read from the tokens on every settings change.
    public private(set) var metrics: TabStripMetrics = .standard

    /// Empty strip space in the window's top row acts as a titlebar (`actsAsTitlebar`).
    public var dragsWindowFromEmptySpace = true
    /// The + button's tooltip ("New Tab (hold for more)"); nil: none.
    public var newTabToolTip: String? {
        get { newTabButton.themedToolTip }
        set { newTabButton.themedToolTip = newValue }
    }
    /// The + action's shortcut as the person sees it ("⌘T"), read when the pointer comes onto the +.
    public var newTabShortcut: (() -> String?)? {
        get { newTabButton.shortcut }
        set { newTabButton.shortcut = newValue }
    }
    /// A pane exposes its type menu on a normal press, with a visible chevron.
    public var opensNewTabMenuOnPress = false {
        didSet {
            newTabButton.showsChevron = opensNewTabMenuOnPress
            newTabButton.themedToolTip = opensNewTabMenuOnPress ? Strings.axNewTab : Strings.newTabHoldHint
            applyTokens(animated: false)
        }
    }
    var windowControlsInset: CGFloat = 0

    /// Builds right-click menus from the App's action registry. With no
    /// provider (or a nil menu for a chip), right-clicking a chip opens the
    /// group editor bubble.
    public var contextMenuProvider: TabContextMenuProvider?
    /// Native menu tracking; injectable for interaction tests without a nested event loop.
    var presentNewTabMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Inline rename (`TabInlineRename`).
    private(set) lazy var inlineRename = TabInlineRename(strip: self)
    // MARK: Views

    var glassView: GlassPanelView?
    let contentView = FlippedView()
    let tabsClip = FlippedView()
    /// Holds the scrolling tabs, group chips and bands in `tabsClip`'s coordinates plus `scroller`'s translation
    /// (its bounds origin less its frame origin) and clips them to after the fixed pinned band, so a tab scrolled
    /// under the pinned tabs never draws over them (`TabScrollMapping`, cx-kp9b4). Fixed pinned tabs sit in `tabsClip`.
    let scrollingLayer = CALayer()
    private(set) lazy var scroller = TabStripScroller(strip: self) // wheels and trackpads scroll by translation
    private(set) lazy var edgeFade = TabEdgeFade(strip: self)
    let newTabButton = NewTabButtonView()
    let hoverCard = TabHoverCardController()
    let groupEditor = TabGroupEditorController()

    // MARK: Layout and animation state

    /// Layer-drawn tabs. One CALayer tree per tab, no NSView per tab.
    var cells: [TabID: TabCell] = [:]
    let windowMain = WindowMainObserver()
    let windowVisibility = WindowVisibilityObserver()
    /// Runs ``syncShown(_:)`` on each flip of ``visibilityNode``.
    private var visibilityWatch: VisibilitySubscription?
    /// In a window and its node visible: written only by `syncShown` (TabStripView+Shown), read instead of an
    /// ancestor walk; the window-wide fan-outs reach the strip.
    var isShownInWindow = false
    /// Group chips, bands, drag, and optimistic membership.
    var groups = TabStripGroupState()
    /// Every tab's and chip's target geometry (`TabPlace`); Core Animation shows the motion to it.
    var placed: [TabID: TabPlace] = [:]
    var dying: Set<TabID> = []
    /// A closing tab's left neighbour when it closed (nil entry: it was the first tab); `pinClosingTabs`
    /// pins the closing tab to that tab's slot, so a tab opened meanwhile cannot move it a slot.
    var closingAnchors: [TabID: TabID?] = [:]
    /// Tabs in visual order, excluding dying and torn-out tabs.
    var displayed: [TabItem] = []
    var result = TabLayoutResult(slots: [], contentWidth: 0, standardWidth: 0, availableWidth: 0) {
        didSet { slotIndexCache = nil }
    }
    /// `result` indexed by tab (`slotIndex`), built on first use after each layout.
    var slotIndexCache: TabSlotIndex?
    /// The strip moves whose Core Animation transaction has not completed (`applyFrames`, `moveEnded`).
    var movesInFlight: Set<Int> = []
    /// Passes over every cell, by kind (`occlusion`, `separators`, `frames`): what a change cost, for
    /// the switch work budget (a tab switch at rest runs none, at any tab count).
    var rowPasses = TabStripRowPasses()
    /// The strip's scroll offset (its target; a reveal's spring is a Core Animation move).
    var scrollOffset: CGFloat = 0
    /// The last strip move's generation (`TabStripMove`).
    var moveGeneration = 0
    /// When a closing tab's or chip's last move ends: it goes then (`moveEnded`).
    var goesAt: [TabID: CFTimeInterval] = [:]
    /// Takes the scroll part of every move (a reveal's spring, a relayout that keeps the selected tab
    /// in view) and nothing else: what they add now is its presentation x minus its model x (`TabStripScroller.settle`).
    let scrollProbe: CALayer = {
        let probe = CALayer()
        probe.actions = ["position": NSNull(), "bounds": NSNull()]
        probe.opacity = 0
        return probe
    }()
    /// Tabs whose occlusion mask follows the moves in flight, and when that path ends (`updateOcclusion`).
    var occlusionEnds: [TabID: CFTimeInterval] = [:]
    var closingModeWidth: CGFloat?
    var closingHit = TabClosingModeHit()
    /// Closing mode's exit: the pointer leaving the strip's extended area (`TabClosingModeWatch`).
    private(set) lazy var closingWatch = TabClosingModeWatch(strip: self)
    var hasSynced = false
    var lastSelectedID: TabID?
    var lastModelOrder: [TabID] = []
    /// The model input of the last sync (`syncFromModel` skips its echo).
    var lastSyncedInput: ModelSnapshot?
    var lastStyle: TabStripStyle?
    var lastViewportWidth: CGFloat = -1
    /// Drag autoscroll steps on the window's one `MotionClock`; nothing else in the strip does.
    weak var motionClock: MotionClock?
    var observationTask: Task<Void, Never>?
    var tokenObservationTask: Task<Void, Never>?

    // MARK: Pointer state

    var hoveredID: TabID?
    /// The hovered tab changed (nil: the pointer left every tab); the App wakes a hidden page ahead of the click.
    public var onHoverTab: ((TabID?) -> Void)?
    var closeHoveredID: TabID?
    var pressedCloseID: TabID?
    /// A press on a tab's speaker (`TabCell.audioButtonRect`): its release there mutes or unmutes the tab.
    var pressedAudioID: TabID?
    /// The tab whose speaker the pointer is on: its fill and the strip's tooltip.
    var audioHoveredID: TabID?
    var middlePressID: TabID?
    var pressedNewTab = false
    /// Press-and-hold on + opens the new tab menu (`TabNewTabHold`).
    private(set) lazy var newTabHold = TabNewTabHold(strip: self)
    /// Whether the plus shows (pointer, open menu, VoiceOver focus): the
    /// strip's inputs to `reveal` (HoverReveal, R120).
    var buttonReveal = TabStripButtonReveal() {
        didSet { reveal.sync(buttonReveal, from: oldValue) }
    }
    private(set) lazy var reveal = TabStripRevealController(strip: self)
    /// Strip elements (the strip, tab elements, the plus) VoiceOver focuses now.
    var accessibilityFocusedElements: Set<ObjectIdentifier> = []
    /// Open menus keep the trailing buttons (`TabMenuTracking`).
    private(set) lazy var menuTracking = TabMenuTracking(strip: self)

    typealias Drag = TabStripDrag
    var press: TabStripPress?
    var drag: TabStripDrag?
    /// Order shown after a local reorder until the model's order changes.
    var orderOverride: [TabID]?
    let reorderSettle: MainDeadline  // ends a reorder the model never shows
    /// Click-and-hold on a chip opens its editor (`startChipHold`): the person waits on it.
    private(set) lazy var chipHold = MainDeadline(owner: "TabStrip.chipHold", workClass: .userBlocking, scheduler: deadlines)
    /// Tab torn out of this strip and handed to the App's drag session. Its
    /// slot stays collapsed until the model drops it or the App restores it.
    var detachedID: TabID?
    /// The other selected tabs of a multi-tab drag: hidden while it runs (stacked under the
    /// dragged tab), shown again at the drop.
    var dragCompanions: Set<TabID> = []
    /// A multi-tab drop's order: it stays shown while the App lands it one move at a time.
    var multiReorderTarget: [TabID]?
    private(set) lazy var selectionEscape = TabStripEscape.multiSelectionClear(strip: self)
    var dropPlaceholderIndex: Int?  // display index of the phantom gap shown for an external drag
    var phantomPoint: CGPoint?  // pointer of the external drag, in view coordinates, for edge autoscroll
    private(set) lazy var escapeMonitor = TabStripEscape.dragCancel(strip: self)
    var pendingDrop: (id: TabID, x: CGFloat, width: CGFloat)?  // a dropped tab keeps the placeholder's geometry
    /// Group the phantom gap belongs to (a dropped tab would join it).
    var dropPlaceholderGroup: TabGroupID?
    static let placeholderID = TabID("__cmux.tabs.drop-placeholder__")
    // MARK: - Init

    /// - Parameters:
    ///   - deadlines: The app's one deadline placer (`AppServices.mainDeadlines`).
    ///   - visibilityNode: The node the strip shows under (its pane's, or its bar's workspace's); the strip's own
    ///     ``visibilityNode`` is its child.
    public init(model: TabStripModel, background: Background = .none, input: InputEventTap, deadlines: MainDeadlineScheduler,
                visibilityNode parent: VisibilityNode) {
        self.model = model
        inputTap = input
        self.deadlines = deadlines
        visibilityNode = VisibilityNode("tabs.strip", parent: parent)
        reorderSettle = MainDeadline(owner: "TabStrip.reorderSettle", workClass: .visible, scheduler: deadlines)
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.preferredHeight))
        visibilityWatch = visibilityNode.subscribe(owner: "TabStripView.shown") { [weak self] _ in self?.syncShown() }
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        hoverCard.strip = self

        switch background {
        case .none:
            addSubview(contentView)
        case .glass:
            // Concentric corners: the strip radius is the tab radius plus the inset around tabs.
            let glass = Glass.makePanel(content: contentView, cornerRadius: metrics.cornerRadius + metrics.stripVerticalPadding)
            glass.translatesAutoresizingMaskIntoConstraints = true
            addSubview(glass)
            glassView = glass
        }
        contentView.wantsLayer = true
        tabsClip.wantsLayer = true
        tabsClip.layer?.masksToBounds = true
        scrollingLayer.masksToBounds = true
        scrollingLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        tabsClip.layer?.addSublayer(scrollingLayer)
        contentView.addSubview(tabsClip)
        contentView.addSubview(newTabButton)
        newTabButton.onPress = { [weak self] in
            guard let self else { return }
            if opensNewTabMenuOnPress { showNewTabMenu() }
            else { model.send(.newTab(after: nil)) }
        }
        newTabButton.onAccessibilityFocus = { [weak self, weak newTabButton] focused in
            guard let newTabButton else { return }
            self?.noteAccessibilityFocus(ObjectIdentifier(newTabButton), focused)
        }
        reveal.install()
        groupEditor.onCommand = { [weak self] command in self?.model.send(.group(command)) }
        groupEditor.onMore = { [weak self] id in self?.showGroupMenu(for: id) }

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Strings.axStrip)
        setAccessibilityIdentifier("cmux.tabs.strip")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeForHover, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Keyboard navigation (the key view loop, Full Keyboard Access) may focus the strip, where F2
    /// renames the selected tab (#17188). A click never does: the window would make the strip first
    /// responder on mouse-down and the focus model would move the keyboard back to the content, one
    /// responder hop per tab click; the keyboard stays where it is. While an inline rename edits, a
    /// click in the strip still takes the keyboard, which ends (commits) the rename.
    public override var acceptsFirstResponder: Bool {
        if inlineRename.field != nil { return true }
        // The event asking is the one in dispatch: the tap's last dispatched event.
        return inputTap.lastDispatched?.type.isButtonDown != true
    }

    /// F2 starts the same inline editor as a screen-tab double-click. The
    /// strip owns this path so pane tabs and screen tabs share one editor.
    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if event.keyCode == 120, flags.isEmpty, let selectedID = model.selectedID {
            beginInlineRename(selectedID)
            return
        }
        super.keyDown(with: event)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.stripHeight)
    }

    // Every event is handled here, never by a tab subview.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    /// VoiceOver on the strip itself reveals the plus (`noteAccessibilityFocus`).
    public override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        noteAccessibilityFocus(ObjectIdentifier(self), accessibilityFocused)
    }

    public override func accessibilityChildren() -> [Any]? {
        scroller.land() // the elements' frames are written where the tabs show
        var children: [Any] = []
        for slot in result.slots where !slot.isCollapsed {
            if let group = slot.id.chipGroupID, let chip = groups.chips[group] {
                children.append(chip.accessibility)
            } else if let cell = cells[slot.id] {
                children.append(cell.accessibility)
            }
        }
        if !newTabButton.isHidden { children.append(newTabButton) }
        return children
    }

    // MARK: - Lifecycle

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // A move to another window (or none) ends this strip's card only.
        if newWindow !== window { syncShown(false) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncShown()
        if window != nil {
            applyTokens(animated: false)
            startObserving()
            startObservingTokens()
            sync(fromModel: true)
        } else {
            observationTask?.cancel()
            observationTask = nil
            tokenObservationTask?.cancel()
            tokenObservationTask = nil
            motionClock?.stop(self)
            motionClock = nil
            endPointerState()
        }
    }

    func applyTokens(animated: Bool) {
        metrics = customMetrics ?? TabStripMetrics()
        if opensNewTabMenuOnPress { metrics.newTabButtonWidth += Metrics.space4 }
        hoverCard.tokensChanged()
        geometryDidChange()
        let font = Typography.body
        for cell in cells.values {
            cell.metrics = metrics
            cell.titleFont = font
        }
        for chip in groups.chips.values {
            chip.metrics = metrics
            chip.font = Typography.caption
        }
        groupEditor.hide()
        // Runs for new tokens (`startObservingTokens`' change check), new custom metrics or a new window.
        newTabButton.needsLayout = true // invalidate: the + button's glyph follows the metrics
        glassView?.cornerRadius = metrics.cornerRadius + metrics.stripVerticalPadding
        invalidateIntrinsicContentSize()
        lastViewportWidth = -1
        needsLayout = true // invalidate: every cell takes the new metrics
        // sync-layout: relayout below reads the viewport the new metrics give (tabsClip, placed in layout()).
        layoutSubtreeIfNeeded()
        relayout(animated: animated && !reduceMotion)
    }

    public override func layout() {
        super.layout()
        glassView?.frame = bounds
        if glassView == nil { contentView.frame = bounds }
        let padding = metrics.stripHorizontalPadding
        windowControlsInset = computeWindowControlsInset()
        let viewport = max(0, bounds.width - 2 * padding - windowControlsInset - (model.showsNewTabButton ? metrics.newTabButtonWidth : 0))
        tabsClip.frame = CGRect(x: padding + windowControlsInset, y: 0, width: viewport, height: bounds.height)
        if viewport != lastViewportWidth {
            // Tabs resize with the window instantly; a close in flight keeps its spring (cx-y2uf5); a narrower strip (a split) keeps the selected tab in view.
            relayout(animated: !dying.isEmpty && !Motion.isLiveResizing(window) && !reduceMotion, keepsSelectedInView: viewport < lastViewportWidth)
            lastViewportWidth = viewport
        } else {
            applyFrames()
        }
    }

    // The closing-mode watch's rect area lives on the content view and covers the strip's bounds plus Chrome's exit pads.
    // tracking-area: the strip's own area is added once (init); this only moves the closing-mode watch's rect area.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        closingWatch.updateTracking()
    }

    /// Movement snaps: Reduce Motion or `ui.animationSpeed` "off".
    var reduceMotion: Bool { !Motion.tabs.animatesMovement }

    var viewportWidth: CGFloat { tabsClip.bounds.width }

    /// Tabs are vertically centered in whatever height the strip gets.
    var tabTop: CGFloat {
        metrics.tabTop(stripHeight: bounds.height, scale: window?.backingScaleFactor ?? 2)
    }
}
