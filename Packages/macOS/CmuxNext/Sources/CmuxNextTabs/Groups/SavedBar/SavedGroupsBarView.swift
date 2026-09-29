public import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// A compact row of saved group chips (Chrome's saved tab groups bar).
/// One view; chips are CALayers in one content layer that scrolls
/// horizontally (trackpad or wheel) when the chips overflow. Click reopens a
/// group; right-click asks `contextMenuProvider` with `.savedGroup(id)`.
public final class SavedGroupsBarView: NSView {
    public static var preferredHeight: CGFloat { Metrics.tabHeight }

    public let model: SavedGroupsBarModel
    public var contextMenuProvider: TabContextMenuProvider?

    private var chips: [TabGroupID: TabGroupChipCell] = [:]
    private var order: [TabGroupID] = []
    private var hovered: TabGroupID?
    private var pressed: TabGroupID?
    private var observation: Task<Void, Never>?
    private var tokenObservation: Task<Void, Never>?
    private var metrics = TabStripMetrics.standard
    /// Holds the chips; its bounds origin is the scroll offset.
    private let contentLayer = CALayer()
    /// Width of all chips plus padding.
    private(set) var contentWidth: CGFloat = 0
    /// Horizontal scroll position, 0...maxScrollOffset.
    private(set) var scrollOffset: CGFloat = 0
    var maxScrollOffset: CGFloat { max(0, contentWidth - bounds.width) }

    public init(model: SavedGroupsBarModel) {
        self.model = model
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

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight) }

    public override func accessibilityChildren() -> [Any]? {
        order.compactMap { chips[$0]?.accessibility }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            observation?.cancel()
            tokenObservation?.cancel()
            observation = nil
            tokenObservation = nil
            return
        }
        sync()
        guard observation == nil else { return }
        let model = model
        observation = Task { [weak self] in
            for await _ in Observations({ model.groups }) {
                guard let self else { return }
                self.sync()
            }
        }
        tokenObservation = Task { [weak self] in
            for await snapshot in Observations({ TabStripMetrics() }) {
                guard let self else { return }
                if snapshot != self.metrics { self.sync() }
            }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for chip in chips.values { chip.appearance = effectiveAppearance }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func sync() {
        metrics = TabStripMetrics()
        let ids = model.groups.map(\.id)
        for (id, chip) in chips where !ids.contains(id) {
            chip.layer.removeFromSuperlayer()
            chips[id] = nil
        }
        for saved in model.groups {
            let item = TabGroupItem(id: saved.id, name: saved.name, colorToken: saved.colorToken)
            let chip = chips[saved.id] ?? makeChip(item, count: saved.tabCount)
            chip.update(group: item, memberCount: saved.tabCount)
            chip.metrics = metrics
            chip.font = Typography.caption
        }
        order = ids
        needsLayout = true
    }

    private func makeChip(_ item: TabGroupItem, count: Int) -> TabGroupChipCell {
        let chip = TabGroupChipCell(group: item, memberCount: count)
        chip.alwaysShowsCount = true
        chip.appearance = effectiveAppearance
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

    public override func scrollWheel(with event: NSEvent) {
        // Trackpads scroll horizontally; a plain mouse wheel's vertical
        // motion scrolls the bar too, like Chrome's tab strip.
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

    public override func mouseMoved(with event: NSEvent) {
        setHovered(chip(at: convert(event.locationInWindow, from: nil)))
    }

    public override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    public override func mouseDown(with event: NSEvent) {
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
