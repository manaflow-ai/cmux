public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "vim" pill in the terminal's top-right corner while copy mode is on
/// (the old app's copy-mode indicator). The theme's raised surface and a
/// hairline, like the status pill, never macOS's HUD material. Clicks go to
/// the terminal below.
final class TerminalCopyModeBadge: NSView {
    static var text: String {
        String(localized: "terminal.copyMode.indicator", defaultValue: "vim", bundle: .module)
    }

    private let icon = ThemedImageView(image: NSImage.icon(.terminalCopymode, size: 14))
    private let label = ThemedLabel(labelWithString: TerminalCopyModeBadge.text)
    /// The icon's box: the 14 pt glyph centered in 16 pt.
    private static let iconBox = CGSize(width: 16, height: 16)
    /// The badge's inset from the terminal's top and trailing edges.
    static let inset: CGFloat = 8

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = Metrics.lineWidth(1)

        icon.ink = .secondary
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(icon)
        addSubview(label)
        setFrameSize(chipLayout.preferredSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // visibility-walk-allow: the body only sets the chip layer's two colors (applyThemeColors: performWithTheme resolves the theme's appearance), R-appear's kept form
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    private func applyThemeColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Frame layout

    /// The icon 10 pt from the leading edge, the label 6 pt after it and 12 pt from the trailing
    /// edge, 6 pt above and below the label.
    var chipLayout: ChipLayout {
        ChipLayout(items: [ChipLayout.Item(Self.iconBox), ChipLayout.Item(label.intrinsicContentSize, flexible: true)],
                   spacing: 6, insets: ChipLayout.Insets(top: 6, leading: 10, bottom: 6, trailing: 12))
    }

    override var fittingSize: NSSize { chipLayout.preferredSize }

    override var intrinsicContentSize: NSSize { chipLayout.preferredSize }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) re-frames the icon and label
    }

    override func layout() {
        super.layout()
        let frames = chipLayout.frames(in: bounds.size, rightToLeft: userInterfaceLayoutDirection == .rightToLeft)
        guard frames.count == 2 else { return }
        // The box is the icon's frame, not its alignment rect: it centers the glyph as the old fixed size did.
        if icon.frame != frames[0] { icon.frame = frames[0] }
        label.setAlignmentFrame(frames[1])
    }

    /// Puts the badge `inset` from `host`'s top and trailing edges, where it stays as `host` resizes
    /// (its autoresizing mask; no constraints).
    func pin(toTopTrailingOf host: NSView) {
        let size = chipLayout.preferredSize
        let bounds = host.bounds
        let rightToLeft = host.userInterfaceLayoutDirection == .rightToLeft
        let x = rightToLeft ? bounds.minX + Self.inset : bounds.maxX - Self.inset - size.width
        let y = host.isFlipped ? bounds.minY + Self.inset : bounds.maxY - Self.inset - size.height
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        // Flexible on the side away from the corner, so the corner's distances stay fixed.
        autoresizingMask = [rightToLeft ? .maxXMargin : .minXMargin, host.isFlipped ? .maxYMargin : .minYMargin]
    }
}
