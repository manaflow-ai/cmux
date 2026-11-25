import AppKit
import CmuxNextDesign

/// One port in the workspace hover card ("localhost:5173", `WorkspaceHoverCardContent.ports`): the shared fact row
/// on the card's icon and text columns, a button drawn like the card's tab rows and its Show details control. A click
/// opens the port in a browser tab of the workspace (`onPress`, the controller's `SidebarIntent.openPort`). Its hover
/// and pressed fill is the tab rows' small-radius rect, reaching `WorkspaceTabHoverCardRow.fillOutset` past both
/// edges so the icon stays on the column.
@MainActor
final class WorkspaceHoverCardPortRow: NSView {
    let row = HoverCardRowView()
    var onPress: (() -> Void)?
    /// The hover and pressed fill, wider than the view by the rows' outset.
    private let fillLayer = CALayer()
    private var tracking: NSTrackingArea?
    /// Set by the pointer (and by the gallery, to show the hover fill).
    var isHovered = false { didSet { paint() } }
    private var pressed = false { didSet { paint() } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        fillLayer.cornerRadius = SidebarDensityTokens.rowCornerRadius
        fillLayer.cornerCurve = Metrics.tabCornerCurve // one curve with the rows and tabs (`TabCornerCurve`)
        layer?.masksToBounds = false
        layer?.addSublayer(fillLayer)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `fact` (its label in the message ink, a step above the metadata facts) beside `image`.
    func configure(_ fact: WorkspaceHoverCardContent.Fact, image: NSImage?, font: NSFont, iconSide: CGFloat) {
        var shown = fact.row
        shown.ink = .primary
        row.iconSide = iconSide
        row.configure(shown, image: image, font: font)
        setAccessibilityLabel(fact.text)
    }

    /// A click from code (tests, the gallery, VoiceOver).
    func performClick(_: Any?) { onPress?() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.cornerRadius = SidebarDensityTokens.rowCornerRadius
        fillLayer.frame = bounds.insetBy(dx: -WorkspaceTabHoverCardRow.fillOutset, dy: 0)
        CATransaction.commit()
    }

    func applyColors() {
        row.applyColors()
        paint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        isHovered = false
        pressed = false
    }

    override func mouseEntered(with _: NSEvent) { isHovered = true }
    override func mouseExited(with _: NSEvent) { isHovered = false }
    override func mouseDown(with _: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }

    private func updateTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func paint() {
        performWithTheme {
            let fill = pressed ? Palette.pressedFill : (isHovered ? Palette.hoverFill : .clear)
            ChromeHover.paint(fillLayer, fill, animated: false)
        }
    }
}
