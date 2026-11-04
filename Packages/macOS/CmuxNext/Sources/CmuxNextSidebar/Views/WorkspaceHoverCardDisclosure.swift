import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The workspace card's Show details / Hide details control, drawn like the card's tab rows: a
/// disclosure chevron on the rows' icon column, the words on their text column in the
/// secondary ink, and the rows' hover and pressed fill (Leo 2026-11-01: "make the thing a little
/// bit less completely unstyled"). It sits on the card's grid (Lawrence msg 19245): the chevron centers on
/// the icon column, the words start on the text column, and the fill reaches
/// `WorkspaceTabHoverCardRow.fillOutset` past both edges, as a tab row's does.
@MainActor
final class WorkspaceHoverCardDisclosure: NSView {
    /// A row plus `space1` at the sidebar's density and text size (``SidebarHoverCardMetrics/disclosureHeight``).
    static var height: CGFloat { SidebarRowTokens.current.hoverCard.disclosureHeight }
    private var heightConstraint: NSLayoutConstraint?
    private var chevronX: NSLayoutConstraint?
    private var labelX: NSLayoutConstraint?
    private let chevron = NSImageView()
    private let label = ChromeLabel(labelWithString: "")
    /// The hover and pressed fill, wider than the view by the rows' outset.
    private let fillLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { paint() } }
    private var pressed = false { didSet { paint() } }
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var isExpanded = false {
        didSet {
            chevron.image = NSImage.icon(isExpanded ? .disclosureExpanded : .disclosureCollapsed, size: Metrics.smallIconSize)
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        fillLayer.cornerRadius = Metrics.itemCornerRadius
        fillLayer.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.addSublayer(fillLayer)
        chevron.imageScaling = .scaleProportionallyDown
        chevron.image = NSImage.icon(.disclosureCollapsed, size: Metrics.smallIconSize)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(label)
        // The chevron centres on the card's icon column, so the words start where a tab's title does.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        let chevronX = chevron.centerXAnchor.constraint(equalTo: leadingAnchor, constant: WorkspaceHoverCardView.iconSize / 2)
        let labelX = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: WorkspaceHoverCardView.textInset)
        (heightConstraint, self.chevronX, self.labelX) = (height, chevronX, labelX)
        NSLayoutConstraint.activate([
            height,
            chevronX,
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Metrics.smallIconSize),
            chevron.heightAnchor.constraint(equalToConstant: Metrics.smallIconSize),
            // The label's alignment rect is its text: the words start on the text column.
            labelX,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applySizes()
        updateTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Takes the card's sizes at the sidebar's density and text size now; the card runs it on every configure.
    func applySizes() {
        let card = SidebarRowTokens.current.hoverCard
        label.font = Typography.system(.default, size: card.captionSize, weight: .regular)
        heightConstraint?.constant = card.disclosureHeight
        chevronX?.constant = WorkspaceHoverCardView.iconSize / 2
        labelX?.constant = WorkspaceHoverCardView.textInset
    }

    /// A click from code (tests, the gallery, VoiceOver).
    func performClick(_: Any?) { onPress?() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds.insetBy(dx: -WorkspaceTabHoverCardRow.fillOutset, dy: 0)
        CATransaction.commit()
    }

    func applyColors() {
        performWithTheme {
            label.textColor = Palette.textSecondary
            chevron.contentTintColor = Palette.textSecondary
        }
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
