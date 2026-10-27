public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextWakeups
import Observation
import QuartzCore

/// A compact row of saved group chips (the saved tab groups bar).
/// One view; chips are CALayers in one content layer that scrolls
/// horizontally (trackpad or wheel) when the chips overflow. Click reopens a
/// group; right-click asks `contextMenuProvider` with `.savedGroup(id)`.
public final class SavedGroupsBarView: NSView {
    public static var preferredHeight: CGFloat { Metrics.controlHeight }

    public let model: SavedGroupsBarModel
    public var contextMenuProvider: TabContextMenuProvider?

    private(set) var chips: [TabGroupID: TabGroupChipCell] = [:]
    private var order: [TabGroupID] = []
    private(set) var hovered: TabGroupID?
    /// The bar's hover moves (feature `pointerFrameHover`, `hoverFrameInput`).
    private lazy var frameInputHover = PointerFrameHover(owner: "SavedGroupsBarView.hover", view: self) { [weak self] point in
        self?.hover(atWindowPoint: point)
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight) }

    public override func accessibilityChildren() -> [Any]? {
        order.compactMap { chips[$0]?.accessibility }
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
    }

    /// Moves the content layer to `scrollOffset` and keeps accessibility
    /// frames in view coordinates.
    private func applyScroll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        contentLayer.bounds = CGRect(x: scrollOffset, y: 0, width: bounds.width, height: bounds.height)
        CATransaction.commit()
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

    // local-monitor-allow: each wheel or trackpad delta scrolls the bar in order, 1:1 with the fingers (a forwarded event keeps its order and count)
    public override func scrollWheel(with event: NSEvent) {
        // Trackpads scroll horizontally; a plain mouse wheel's vertical
        // motion scrolls the bar too, like the tab strip.
        var delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= metrics.tabHeight / 2 }
        guard delta != 0, scroll(by: -delta) else { return super.scrollWheel(with: event) }
        if let window { setHovered(chip(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
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
