import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextUpdater

/// The "cmux Updated!" card, native (Lawrence 2026-12: no React in small things like popovers and
/// toasts). Two lines on the host's native glass (``SidebarUpdatedCardHost/glass``, the composer's material and
/// corner; this view paints none, ``paintsOwnGlass``): "Updated to Nightly" (a click copies the version) with What's New, and the top change
/// ("Fixed: …"). The host draws the x on the title line (``titleLineMid``), the frost while the card
/// stands over rows, and runs the drag this view reports (``onDrag``). Leo's look churn came from the
/// page's CSS glass beside the native glass; now both are the same view.
@MainActor
final class UpdatedCardIsland: SidebarSurfaceIsland {
    private weak var services: AppServices?
    private let card = UpdatedCardView()
    var view: NSView { card }
    var onHeightChange: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDrag: ((SidebarCardDrag) -> Void)? {
        get { card.onDrag }
        set { card.onDrag = newValue }
    }
    private var task: Task<Void, Never>?
    private var reportedHeight: CGFloat = 0

    var contentHeight: CGFloat { card.text == nil ? 0 : card.fittingHeight }
    var titleLineMid: CGFloat { card.titleLineMid }
    var contentSettled: Bool { true }
    var paintsOwnGlass: Bool { false }

    init(services: AppServices?) {
        self.services = services
        card.onWhatsNew = { [weak self] in
            _ = self?.services?.updater.openWhatsNewForLastUpdate()
            self?.onAction?()
        }
        card.onResize = { [weak self] in self?.reportIfChanged() }
        // task-owner: the island's; cancelled in close().
        task = Task { @MainActor [weak self] in
            for await highlights in ObservationStream({ [weak self] in self?.services?.updater.surfaceHighlights(updated: true) }) {
                guard let self else { return }
                card.text = highlights.map { UpdatedCardText($0, background: services?.environment.relaunchBehind != nil) }
                reportIfChanged(force: true)
            }
        }
    }

    private func reportIfChanged(force: Bool = false) {
        let height = contentHeight
        guard force || height != reportedHeight else { return }
        reportedHeight = height
        onHeightChange?()
    }

    func close() { task?.cancel() }
    func setPlace(_ place: SidebarCardPlace) { card.place = place }
}

/// The card's own view: glass, the headline row and the change line. Flipped.
@MainActor
final class UpdatedCardView: NSView {
    private let headline = ThemedLabel(font: Typography.cardTitle)
    private let whatsNew = UpdatedCardLink()
    private let area = ThemedLabel(font: Typography.cardBody)
    private let line = ThemedLabel(font: Typography.cardBody)
    private var copiedUntil: Task<Void, Never>?
    var onWhatsNew: (() -> Void)?
    var onResize: (() -> Void)?
    var onDrag: ((SidebarCardDrag) -> Void)?
    var place = SidebarCardPlace(anchor: .bottom, above: 0, below: 0)
    private var press: (start: NSPoint, dragging: Bool)?

    var text: UpdatedCardText? {
        didSet { if text != oldValue { apply() } }
    }

    private static var metrics: SidebarCardMetrics { SidebarRowTokens.current.card }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        headline.ink = .primary
        area.ink = .primary
        line.ink = .secondary
        [headline, area, line].forEach { $0.setAccessibilityElement(true) }
        whatsNew.onPress = { [weak self] in self?.onWhatsNew?() }
        [headline, whatsNew, area, line].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func apply(copied: Bool = false) {
        guard let text else { return }
        headline.stringValue = copied ? "\(text.headline) · \(text.copied)" : text.headline
        headline.setAccessibilityLabel(text.headline)
        headline.setAccessibilityHelp(text.copyVersion)
        whatsNew.text = text.whatsNew
        area.stringValue = text.area ?? ""
        area.isHidden = text.area == nil
        line.stringValue = text.line
        setAccessibilityLabel(text.headline)
        needsLayout = true
        onResize?()
    }

    private var lineHeight: (title: CGFloat, body: CGFloat) {
        (ceil(Typography.cardTitle.boundingRectForFont.height), ceil(Typography.cardBody.boundingRectForFont.height))
    }

    /// Padding, the headline row, the gap, the change line, padding.
    var fittingHeight: CGFloat {
        let m = Self.metrics, h = lineHeight
        return ceil(2 * m.paddingY + max(h.title, UpdatedCardLink.height) + m.gap + h.body)
    }

    /// The headline row's middle from the card's top: the host centers its x there.
    var titleLineMid: CGFloat {
        text == nil ? 0 : Self.metrics.paddingY + max(lineHeight.title, UpdatedCardLink.height) / 2
    }

    /// The room the host's x takes at the headline row's end.
    private var closeRoom: CGFloat { Self.metrics.closeSide + Metrics.space1 }

    override func layout() {
        super.layout()
        let m = Self.metrics, h = lineHeight, b = bounds
        headline.font = Typography.cardTitle
        area.font = Typography.cardBody
        line.font = Typography.cardBody
        let rowHeight = max(h.title, UpdatedCardLink.height)
        let linkWidth = whatsNew.fittingWidth
        let right = b.width - m.paddingX - closeRoom
        whatsNew.frame = NSRect(x: max(m.paddingX, right - linkWidth), y: m.paddingY + (rowHeight - UpdatedCardLink.height) / 2,
                                width: linkWidth, height: UpdatedCardLink.height)
        headline.frame = NSRect(x: m.paddingX, y: m.paddingY + (rowHeight - h.title) / 2,
                                width: max(0, whatsNew.frame.minX - Metrics.space1 - m.paddingX), height: h.title)
        let y = m.paddingY + rowHeight + m.gap
        var x = m.paddingX
        if !area.isHidden {
            let w = min(ceil(area.naturalSize.width), max(0, b.width - 2 * m.paddingX))
            area.frame = NSRect(x: x, y: y, width: w, height: h.body)
            x += w + Metrics.space1 / 2
        }
        line.frame = NSRect(x: x, y: y, width: max(0, b.width - m.paddingX - x), height: h.body)
    }

    // MARK: Click to copy, drag to move

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The labels draw; the card takes their clicks (copy, drag). The link keeps its own.
        return hit.isDescendant(of: whatsNew) ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        press = (event.locationInWindow, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press else { return }
        let offset = Self.offset(from: press.start, to: event.locationInWindow)
        if !press.dragging, hypot(offset.x, offset.y) < Self.dragSlop { return }
        press.dragging = true
        self.press = press
        onDrag?(SidebarCardDrag(offset: offset))
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        let offset = Self.offset(from: press.start, to: event.locationInWindow)
        if press.dragging { return onDrag?(SidebarCardDrag(offset: offset, drop: Self.drop(offset: offset, place: place))) ?? () }
        // A click on the headline copies the version.
        if headline.frame.contains(convert(event.locationInWindow, from: nil)) { copyVersion() }
    }

    /// How far the pointer moves before a press becomes a drag.
    static let dragSlop: CGFloat = 4

    /// The pointer's move in the host's flipped points (y grows down).
    static func offset(from start: NSPoint, to end: NSPoint) -> CGPoint { CGPoint(x: end.x - start.x, y: start.y - end.y) }

    /// Where a card let go at `offset` rests: past half the room toward the other end, there.
    static func drop(offset: CGPoint, place: SidebarCardPlace) -> SidebarCardAnchor {
        switch place.anchor {
        case .bottom: -offset.y > max(place.above, 1) / 2 ? .top : .bottom
        case .top: offset.y > max(place.below, 1) / 2 ? .bottom : .top
        }
    }

    private func copyVersion() {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.version, forType: .string)
        apply(copied: true)
        copiedUntil?.cancel()
        // task-owner: the copied note's; replaced by the next copy.
        copiedUntil = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2)) // hover-timing: how long " · Copied" stays, not a hover delay
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }
}

/// A text link in the card ("What's New", "Other builds"): the cards' button text, secondary,
/// primary with the hover fill under the pointer; a press changes only the fill.
@MainActor
final class UpdatedCardLink: ClickableButton {
    private lazy var hover = ChromeHover(self, behindContent: true)
    var onPress: (() -> Void)?
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            setAccessibilityLabel(text)
            refresh()
        }
    }

    static var font: NSFont { Typography.cardButton }
    static var height: CGFloat { ceil(font.boundingRectForFont.height) + Metrics.space1 }
    var fittingWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 2 * Metrics.space1
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        refusesFirstResponder = true
        target = self
        action = #selector(pressed)
        setAccessibilityRole(.button)
        hover.followPointer(onChange: { [weak self] in self?.refresh() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        performWithTheme {
            let lit = hover.state.hovering || hover.state.pressed
            attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.font,
                                                                             .foregroundColor: lit ? Palette.textPrimary : Palette.textSecondary])
        }
        hover.refresh(animated: false)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        hover.cornerRadius = Metrics.buttonCornerRadius
        hover.refresh(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
        super.mouseDown(with: event)
        hover.state.pressed = false
    }
}
