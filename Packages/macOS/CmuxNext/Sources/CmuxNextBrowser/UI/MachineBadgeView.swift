import AppKit
import CmuxNextDesign

/// The subtle gray chip that names the machine whose localhost a tab sees
/// (plans/cmux-next/remote-localhost.md section 6), at the trailing end of
/// the omnibar. Hidden while the page is not a loopback origin.
final class MachineBadgeView: NSView {
    private let label = ChromeLabel(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        // Beats the URL field (250) beside it: a long URL truncates, not the chip (cx-k9mc).
        setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The badge takes the whole press (not its image or label) and the first
    /// one in a browser window that is not key: one click acts, as Chrome's
    /// omnibar buttons do (user, 2026-10-28, "click the star twice").
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The chip's menu (the host's machine actions); nil: no menu.
    var makeMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return super.mouseDown(with: event) }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: self, gap: 4), in: self)
    }

    func show(text: String, help: String) {
        if label.stringValue != text {
            label.stringValue = text
            invalidateIntrinsicContentSize()
            needsLayout = true // invalidate: new text (the check above) at another width
        }
        themedToolTip = help
        setAccessibilityLabel(help)
        updateLayer()
    }

    // MARK: Frame layout

    /// The label 6 pt from the sides, centered on an 18 pt chip at most 160 pt wide; a longer name truncates.
    var chipLayout: ChipLayout {
        ChipLayout(items: [ChipLayout.Item(label.intrinsicContentSize, flexible: true)],
                   insets: ChipLayout.Insets(horizontal: 6, vertical: 0), minHeight: 18, maxWidth: 160)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: chipLayout.preferredSize.width, height: 18) }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) re-frames the label
    }

    override func layout() {
        super.layout()
        let frames = chipLayout.frames(in: bounds.size, rightToLeft: userInterfaceLayoutDirection == .rightToLeft)
        if let frame = frames.first { label.setAlignmentFrame(frame) }
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.hoverFill.cgColor
            label.textColor = Palette.textSecondary
        }
    }
}
