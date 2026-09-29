public import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// A compact row of saved group chips (Chrome's saved tab groups bar).
/// One view; chips are CALayers. Click reopens a group; right-click asks
/// `contextMenuProvider` with `.savedGroup(id)`.
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

    public init(model: SavedGroupsBarModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.preferredHeight))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
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
        layer?.addSublayer(chip.layer)
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
            chip.accessibility.setAccessibilityFrameInParentSpace(chip.frame)
            x += width + Metrics.space1
        }
        CATransaction.commit()
    }

    private func chip(at point: CGPoint) -> TabGroupID? {
        order.first { id in chips[id].map { $0.frame.contains(point) } ?? false }
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
