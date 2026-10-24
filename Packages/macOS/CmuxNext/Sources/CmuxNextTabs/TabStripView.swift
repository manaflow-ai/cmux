public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
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
    var windowControlsInset: CGFloat = 0

    /// Builds right-click menus from the App's action registry. With no
    /// provider (or a nil menu for a chip), right-clicking a chip opens the
    /// group editor bubble.
    public var contextMenuProvider: TabContextMenuProvider?
    /// Inline rename (`TabInlineRename`).
    private(set) lazy var inlineRename = TabInlineRename(strip: self)
    // MARK: Views

    var glassView: GlassPanelView?
    let contentView = FlippedView()
    let tabsClip = FlippedView()
    /// Holds the unpinned tabs, group chips and bands in `tabsClip`'s coordinates (its bounds origin is its
    /// frame origin) and clips them to after the fixed pinned band, so a tab scrolled under the pinned tabs
    /// never draws over them (`TabScrollMapping`, cx-kp9b4). Pinned tabs sit in `tabsClip` itself.
    let scrollingLayer = CALayer()
    private(set) lazy var edgeFade = TabEdgeFade(strip: self)
    let newTabButton = NewTabButtonView()
    let hoverCard = TabHoverCardController()
    let groupEditor = TabGroupEditorController()
    var trackingArea: NSTrackingArea?

    // MARK: Layout and animation state

    /// Layer-drawn tabs. One CALayer tree per tab, no NSView per tab.
    var cells: [TabID: TabCell] = [:]
    let windowMain = WindowMainObserver()
    let windowVisibility = WindowVisibilityObserver()
    /// In a window and not hidden (`syncShown`).
    private(set) var isShownInWindow = false
    /// The model changed while the strip was out of sight: it syncs once, at rest, when it shows.
    var modelChangedWhileHidden = false
    /// An appearance or scale change came while hidden; applied when shown.
    private var appearanceIsStale = false
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
    /// in view) and nothing else: what they add now is its presentation x minus its model x (`settleScroll`).
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
    let reorderSettle = DemandTimer(owner: "TabStrip.reorderSettle")  // ends a reorder the model never shows
    /// Tab torn out of this strip and handed to the App's drag session. Its
    /// slot stays collapsed until the model drops it or the App restores it.
    var detachedID: TabID?
    /// The other selected tabs of a multi-tab drag: hidden while it runs (stacked under the
    /// dragged tab), shown again at the drop.
    var dragCompanions: Set<TabID> = []
    /// A multi-tab drop's order: it stays shown while the App lands it one move at a time.
    var multiReorderTarget: [TabID]?
    private(set) lazy var selectionEscape = TabSelectionEscapeMonitor(strip: self)
    /// Display index of the phantom gap shown for an external drag.
    var dropPlaceholderIndex: Int?
    /// Pointer of the external drag, in view coordinates, for edge autoscroll.
    var phantomPoint: CGPoint?
    private(set) lazy var escapeMonitor = TabDragEscapeMonitor(strip: self)
    /// A dropped tab keeps the placeholder's geometry when it arrives.
    var pendingDrop: (id: TabID, x: CGFloat, width: CGFloat)?
    /// Group the phantom gap belongs to (a dropped tab would join it).
    var dropPlaceholderGroup: TabGroupID?
    static let placeholderID = TabID("__cmux.tabs.drop-placeholder__")
    // MARK: - Init

    public init(model: TabStripModel, background: Background = .none) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.preferredHeight))
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
        newTabButton.onPress = { [weak self] in self?.model.send(.newTab(after: nil)) }
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
        return switch NSApp.currentEvent?.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: false
        default: true
        }
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

    /// The strip leaves sight (its window, or hidden in it): its editor panel and pointer
    /// state end, since it gets no exit while hidden. Closing mode belongs to this window's
    /// pointer; the strip shown again lays out fully.
    private func endPointerState() {
        groupEditor.hide()
        groups.holdTask?.cancel()
        escapeMonitor.remove()
        selectionEscape.remove()
        closingWatch.end()
        closingModeWidth = nil
        menuTracking.end()
        buttonReveal.pointerInStrip = false
    }

    public override func viewDidHide() {
        super.viewDidHide()
        syncShown(false)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        syncShown()
    }

    /// The window-wide fan-outs (hover-card hit tests, main and occlusion changes) reach only a
    /// shown strip: a hidden one (a parked workspace, still in its window, or a hidden screen bar)
    /// is not in them, and an appearance or scale change waits until it shows. Showing re-reads
    /// the window's state and applies, without motion, the model changes that came while hidden
    /// (``syncFromModel()`` lays nothing out out of sight).
    func syncShown(_ shown: Bool? = nil) {
        let shown = shown ?? (window != nil && !isHiddenOrHasHiddenAncestor)
        guard shown != isShownInWindow else { return }
        isShownInWindow = shown
        hoverCards.unregister(hoverCard)
        windowMain.observe(shown ? window : nil) { [weak self] isMain in self?.cells.values.forEach { $0.isWindowMain = isMain } }
        windowVisibility.observe(shown ? window : nil) { [weak self] visible in self?.cells.values.forEach { $0.isWindowVisible = visible } }
        for cell in cells.values { cell.isStripShown = shown }
        guard shown else {
            if window != nil { endPointerState() }
            return
        }
        // What changed while out of sight lands at once in its final place: nobody saw it move.
        if modelChangedWhileHidden {
            modelChangedWhileHidden = false
            sync(fromModel: true, animating: false)
        }
        hoverCards.register(hoverCard)
        applyMultiSelection()
        if appearanceIsStale {
            appearanceIsStale = false
            applyAppearance()
            applyFrames()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard isShownInWindow || window == nil else {
            appearanceIsStale = true
            return
        }
        applyAppearance()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard isShownInWindow || window == nil else {
            appearanceIsStale = true
            return
        }
        applyAppearance()
        applyFrames()
    }

    /// Layers do not inherit theme scope or scale; push both (re-applies colors).
    func applyAppearance() {
        let scope = themeScope
        let scale = window?.backingScaleFactor ?? 2
        for cell in cells.values {
            cell.themeScope = scope
            cell.scale = scale
        }
        for chip in groups.chips.values {
            chip.themeScope = scope
            chip.scale = scale
        }
        for band in groups.bands.values { band.themeScope = scope }
    }

    func applyTokens(animated: Bool) {
        metrics = customMetrics ?? TabStripMetrics()
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
        newTabButton.needsLayout = true
        glassView?.cornerRadius = metrics.cornerRadius + metrics.stripVerticalPadding
        invalidateIntrinsicContentSize()
        lastViewportWidth = -1
        needsLayout = true
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

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
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
