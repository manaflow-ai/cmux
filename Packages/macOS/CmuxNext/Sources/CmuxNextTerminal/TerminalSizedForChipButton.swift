import AppKit
import CmuxNextDesign

/// Take over on the "Sized for" chip: a borderless button that draws its own fill, so its corner
/// radius is exact and concentric with the chip's (a rounded bezel draws a fixed radius inside its
/// frame). The chip sets ``cornerRadius`` and the colors; a press dims the fill while it is held.
final class TerminalSizedForChipButton: NSButton {
    /// The button's height: the chip's height less its gap above and below.
    static let height: CGFloat = 18
    /// The title's gap to the fill's leading and trailing edges.
    private static let titleInset: CGFloat = 8

    /// The fill's corner radius (the chip's radius less the gap between them).
    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    private var fill: NSColor = .clear
    private var pressed = false {
        didSet { applyFill() }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerCurve = .continuous
        focusRingType = .none
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + Self.titleInset * 2, height: Self.height)
    }

    /// Colors the fill and title (resolved by the caller in the theme's appearance).
    func applyColors(fill: NSColor, title color: NSColor, font: NSFont) {
        self.fill = fill
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: font,
            .paragraphStyle: Self.centered,
        ])
        applyFill()
        invalidateIntrinsicContentSize()
    }

    private func applyFill() {
        layer?.backgroundColor = (pressed ? fill.withAlphaComponent(fill.alphaComponent * 0.6) : fill).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        // AppKit tracks the press inside super until the mouse goes up.
        super.mouseDown(with: event)
        pressed = false
    }

    private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()
}
