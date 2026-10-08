public import AppKit
import CmuxNextDesign

// The footer: its accessory slots, and Back. Leo (T3 Code ref, 2026-10-07):
// while the window shows a full-page destination (`SidebarModel.showsBack`),
// the footer band gives way to one wide Back button in the same spot, a
// universal way back to where you were.
extension SidebarView {
    /// Installs (or removes, with nil) the view in a footer slot.
    public func setAccessory(_ view: NSView?, for slot: SidebarAccessorySlot) {
        accessories[slot]?.removeFromSuperview()
        accessories[slot] = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = true
            footer.addSubview(view)
        }
        needsLayout = true
    }

    func installBackButton() {
        backButton.isHidden = true
        backButton.onPress = { [weak self] in self?.model.onBack?() }
        addSubview(backButton)
    }

    /// Shows Back over the footer band's spot while a destination is open,
    /// and the band's items otherwise.
    func layoutBack() {
        let showsBack = model.showsBack
        backButton.isHidden = !showsBack
        belowFade.isHidden = showsBack
        guard showsBack else { return }
        let b = bounds, band = belowFade.frame
        let height = Metrics.sidebarRowHeight
        let midY = band.height >= height ? band.midY : b.height - Metrics.space2 - height / 2
        backButton.frame = NSRect(x: Metrics.space2, y: (midY - height / 2).rounded(), width: max(0, b.width - Metrics.space2 * 2), height: height)
    }
}

/// The footer's Back button: an arrow and "Back", full width, with the
/// chrome hover look.
final class SidebarBackButton: NSButton {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    var onPress: (() -> Void)?

    /// Insets the arrow and label from the button's leading edge, like a row's icon.
    private final class InsetCell: NSButtonCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            let inset = super.drawingRect(forBounds: rect)
            return NSRect(x: rect.minX + Metrics.space3, y: inset.minY, width: max(0, rect.width - Metrics.space3 * 2), height: inset.height)
        }
    }

    init() {
        super.init(frame: .zero)
        cell = InsetCell()
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        title = Strings.back
        setAccessibilityLabel(Strings.back)
        wantsLayer = true
        target = self
        action = #selector(pressed)
        // Hover follows the pointer and the button's frame (cx-3wu5).
        hover.followPointer()
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override var wantsUpdateLayer: Bool { true }

    /// Only layer properties here: setting the image or title marks the
    /// button for display again, which would redraw it every frame.
    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restyle()
    }

    private func restyle() {
        performWithTheme {
            let color = Palette.textPrimary
            let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .semibold)
            image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            contentTintColor = color
            let leading = NSMutableParagraphStyle()
            leading.alignment = .left
            attributedTitle = NSAttributedString(string: Strings.back, attributes: [.font: SidebarStyle.titleFont, .foregroundColor: color,
                                                                                   .paragraphStyle: leading])
        }
    }
}
