public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextWakeups
import Observation
import QuartzCore

/// A compact row of saved group chips (the saved tab groups bar).
/// One view; chips are CALayers in one content layer that scrolls
/// horizontally (trackpad or wheel) when the chips overflow: a scroll sets
/// that layer's bounds origin and lays out no chip, at most twice per frame
/// with `scrollFrameInput` (as Chrome's layer-backed
/// `views::ScrollView`, ui/views/controls/scroll_view.cc). Click reopens a
/// group; right-click asks `contextMenuProvider` with `.savedGroup(id)`.
public final class SavedGroupsBarView: NSView {
    public static var preferredHeight: CGFloat { Metrics.controlHeight }

    public let model: SavedGroupsBarModel
    public var contextMenuProvider: TabContextMenuProvider?

    private(set) var chips: [TabGroupID: TabGroupChipCell] = [:]
    private var order: [TabGroupID] = []
    private(set) var hovered: TabGroupID?
    /// While a chip hovers (`setHovered`).
    private var deactivationWatch: HoverDeactivationWatch?
    /// The bar's hover moves (feature `pointerFrameHover`, `hoverFrameInput`).
    private lazy var frameInputHover = PointerFrameHover(owner: "SavedGroupsBarView.hover", view: self) { [weak self] point in
        self?.hover(atWindowPoint: point)
    }
    /// The bar's wheel and trackpad scrolls (feature `tabStripScrollFrames`, `scrollFrameInput`).
    private lazy var wheel = PointerFrameWheel(owner: "SavedGroupsBarView.wheel", view: self) { [weak self] scroll in
        self?.scrolled(scroll)
    }
    private var pressed: TabGroupID?
    /// The app's one main-thread scheduler: the bar's observation flushes on it.
    private let mainWork: MainWorkScheduler
    /// The saved groups and the strip tokens, followed while the bar is in a window and the window shows
    /// (``VisibleObservation`` on its window's node: the apply only redraws the chips).
    private var observation: VisibleObservation<([SavedTabGroupItem], TabStripMetrics)>?
    private var metrics = TabStripMetrics.standard
    /// Holds the chips; its bounds origin is the scroll offset.
    private let contentLayer = CALayer()
    /// Width of all chips plus padding.
    private(set) var contentWidth: CGFloat = 0
    /// Horizontal scroll position, 0...maxScrollOffset.
    private(set) var scrollOffset: CGFloat = 0
    var maxScrollOffset: CGFloat { max(0, contentWidth - bounds.width) }
    /// The scroll offset the chips' accessibility frames were written at (nil: none yet); VoiceOver
    /// asking for the chips writes them again after a scroll (`accessibilityChildren`).
    private var accessibilityOffset: CGFloat?
    /// Content layer moves (debug and tests): one per layout and per scroll delivery, none per chip.
    private(set) var scrollApplies = 0

    /// - Parameters:
    ///   - model: The saved groups the bar shows.
    ///   - mainWork: The app's one main-thread scheduler (the demo and tests pass their own).
    public init(model: SavedGroupsBarModel, mainWork: MainWorkScheduler) {
        self.model = model
        self.mainWork = mainWork
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.preferredHeight))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        contentLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(contentLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(Strings.axSavedBar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeForHover, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight) }

    public override func accessibilityChildren() -> [Any]? {
        if accessibilityOffset != scrollOffset { writeAccessibilityFrames() }
        return order.compactMap { chips[$0]?.accessibility }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.cancel()
        observation = nil
        guard let window else { return }
        // The first read syncs now; a hidden window's bar reads nothing until it shows, then syncs once.
        let model = model
        observation = VisibleObservation(WindowVisibilitySource.of(window).node, owner: "SavedGroupsBar.groups", on: mainWork) {
            (model.groups, TabStripMetrics())
        } apply: { [weak self] _ in
            self?.sync()
        }
    }

    // visibility-walk-allow: hands the chips' layers the bar's theme scope only (their colors; no layout)
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let scope = themeScope
        for chip in chips.values { chip.themeScope = scope }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true // invalidate: a new backing scale re-aligns the chips' layers
    }

    func sync() {
        metrics = TabStripMetrics()
        let ids = model.groups.map(\.id)
        for (id, chip) in chips where !ids.contains(id) {
            chip.layer.removeFromSuperlayer()
            chips[id] = nil
        }
        for saved in model.groups {
            let item = TabGroupItem(id: saved.id, name: saved.name, tint: saved.tint, icon: saved.icon)
            let chip = chips[saved.id] ?? makeChip(item, count: saved.tabCount)
            chip.update(group: item, memberCount: saved.tabCount)
            chip.metrics = metrics
            chip.font = Typography.caption
        }
        order = ids
        needsLayout = true // invalidate: new groups or metrics (the observations run on a change only)
    }

    private func makeChip(_ item: TabGroupItem, count: Int) -> TabGroupChipCell {
        let chip = TabGroupChipCell(group: item, memberCount: count)
        chip.alwaysShowsCount = true
        chip.themeScope = themeScope
        chip.accessibility.setAccessibilityParent(self)
        chip.accessibility.setAccessibilityRole(.button)
        let id = item.id
        chip.accessibility.onPress = { [weak self] in self?.model.send(.open(id)) }
        contentLayer.addSublayer(chip.layer)
        chips[id] = chip
        return chip
    }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        var x = metrics.stripHorizontalPadding
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in order {
            guard let chip = chips[id] else { continue }
            chip.scale = scale
            let width = chip.slotWidth
            chip.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Metrics.space1
        }
        contentWidth = order.isEmpty ? 0 : x - Metrics.space1 + metrics.stripHorizontalPadding
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        applyScroll()
        CATransaction.commit()
        writeAccessibilityFrames()
    }

    /// Moves the content layer to `scrollOffset`: one layer, no chip.
    private func applyScroll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        contentLayer.bounds = CGRect(x: scrollOffset, y: 0, width: bounds.width, height: bounds.height)
        CATransaction.commit()
        scrollApplies += 1
    }

    /// The chips' accessibility frames in view coordinates at the current scroll. Written at a layout, a
    /// scroll gesture's end and when VoiceOver asks for the chips, not every scroll frame (Chrome sends
    /// accessibility location changes after the frame, not per scroll: content/renderer/accessibility/
    /// render_accessibility_impl.cc `SendLocationChanges`).
    private func writeAccessibilityFrames() {
        accessibilityOffset = scrollOffset
        for id in order {
            guard let chip = chips[id] else { continue }
            chip.accessibility.setAccessibilityFrameInParentSpace(chip.frame.offsetBy(dx: -scrollOffset, dy: 0))
        }
    }

    /// Scrolls horizontally by `delta` points (positive reveals chips to the
    /// right). Returns false when the bar does not overflow.
    @discardableResult
    func scroll(by delta: CGFloat) -> Bool {
        guard maxScrollOffset > 0 else { return false }
        let offset = min(max(0, scrollOffset + delta), maxScrollOffset)
        guard offset != scrollOffset else { return true }
        scrollOffset = offset
        applyScroll()
        return true
    }

    /// The windows' frame-aligned wheels (feature `tabStripScrollFrames`): a frame interval's first scroll
    /// moves the chips at once and the rest once at its frame, summed per phase. Nil: each event scrolls.
    public var scrollFrameInput: FrameInputCoalescers? {
        get { wheel.frames }
        set { wheel.frames = newValue }
    }

    // local-monitor-allow: the deltas go through the window's FrameInputCoalescer (PointerFrameWheel, feature tabStripScrollFrames); a bar that does not scroll forwards the event up unchanged
    public override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return super.scrollWheel(with: event) }
        wheel.scrolled(event)
    }

    /// One wheel delivery. Trackpads scroll horizontally; a plain mouse wheel's vertical motion scrolls
    /// the bar too, like the tab strip. The chip under the pointer is hit-tested where the chips moved.
    private func scrolled(_ scroll: PointerFrameWheel.Scroll) {
        var delta = abs(scroll.delta.dx) >= abs(scroll.delta.dy) ? scroll.delta.dx : scroll.delta.dy
        if !scroll.isPrecise { delta *= metrics.tabHeight / 2 }
        if delta != 0, self.scroll(by: -delta) { setHovered(chip(at: convert(scroll.location, from: nil))) }
        if scroll.endsGesture || scroll.isNotch, accessibilityOffset != scrollOffset { writeAccessibilityFrames() }
    }

    private func chip(at point: CGPoint) -> TabGroupID? {
        let content = CGPoint(x: point.x + scrollOffset, y: point.y)
        return order.first { id in chips[id].map { $0.frame.contains(content) } ?? false }
    }

    private func setHovered(_ id: TabGroupID?) {
        guard id != hovered else { return }
        if let hovered { chips[hovered]?.isHovered = false }
        hovered = id
        if let id { chips[id]?.isHovered = true }
        // The bar's `.activeForHover` area hears no exit while another app is active: cmux resigning active ends the hover.
        if id == nil {
            deactivationWatch = nil
        } else if deactivationWatch == nil {
            deactivationWatch = PointerHover.clearOnDeactivation { [weak self] in self?.setHovered(nil) }
        }
    }

    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`): a frame interval's first move
    /// hovers at once and the rest once at its frame, at the latest point (Chromium's rAF-aligned moves,
    /// main_thread_event_queue.cc). Nil: each move hovers at once.
    public var hoverFrameInput: FrameInputCoalescers? {
        get { frameInputHover.frames }
        set { frameInputHover.frames = newValue }
    }

    public override func mouseMoved(with event: NSEvent) { frameInputHover.moved(event) }

    /// Hovers the chip under `windowPoint`, hit-tested where the chips are scrolled to now.
    private func hover(atWindowPoint windowPoint: CGPoint) {
        setHovered(chip(at: convert(windowPoint, from: nil)))
    }

    // Exit and a press are discrete: the pending moves land first (Chromium's `ShouldFlushQueue`).
    public override func mouseExited(with event: NSEvent) {
        frameInputHover.flush()
        setHovered(nil)
    }

    public override func mouseDown(with event: NSEvent) {
        wheel.flush()
        frameInputHover.flush()
        pressed = chip(at: convert(event.locationInWindow, from: nil))
        if let pressed { chips[pressed]?.isPressed = true }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let pressed else { return }
        chips[pressed]?.isPressed = false
        self.pressed = nil
        if chip(at: convert(event.locationInWindow, from: nil)) == pressed { model.send(.open(pressed)) }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = chip(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return contextMenuProvider?(.savedGroup(id))
    }
}
