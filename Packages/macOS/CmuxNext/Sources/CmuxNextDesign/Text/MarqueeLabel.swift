public import AppKit

/// A one-line chrome label whose clipped end fades out (no ellipsis) and
/// whose hover marquee reveals the rest (`TitleFade`). Passive: it takes no
/// clicks and is not an accessibility element (its row names itself).
///
/// The view's frame is the text rect at rest. The leading fade uses
/// `leadingPadding` points left of it, which the owner keeps free (its
/// padding), so the view draws outside its bounds there.
public final class MarqueeLabel: NSView {
    private let text = ChromeTextLayer()
    private lazy var fade = TitleFade(textLayer: text)

    public var stringValue: String {
        get { text.string }
        set {
            guard newValue != text.string else { return }
            text.string = newValue
            needsLayout = true
        }
    }

    public var font: NSFont {
        get { text.font }
        set {
            guard newValue != text.font else { return }
            text.font = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Set inside the owner's `performWithTheme`, so it resolves against
    /// the owner's theme scope.
    public var textColor: NSColor = .labelColor {
        didSet { text.foregroundColor = textColor.cgColor }
    }

    public var leadingPadding: CGFloat = 0 { didSet { if oldValue != leadingPadding { needsLayout = true } } }
    public var fadeWidth: CGFloat = Metrics.space6 { didSet { if oldValue != fadeWidth { needsLayout = true } } }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        text.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "mask": NSNull()]
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(text)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(text.textWidth), height: ceil(font.ascender - font.descender + font.leading))
    }

    /// The whole title does not fit.
    public var isTruncated: Bool { fade.geometry?.isTruncated ?? false }
    public var isMarqueeActive: Bool { fade.isMarqueeActive }
    /// The motion policy the marquee follows; tests pin it.
    public var motionPolicy: () -> MotionPolicy {
        get { fade.policy }
        set { fade.policy = newValue }
    }

    /// Starts the hover marquee (after its delay). False when the title
    /// fits or motion is reduced or off.
    @discardableResult
    public func startMarquee() -> Bool {
        layoutSubtreeIfNeeded()
        return fade.startMarquee()
    }

    public func stopMarquee() { fade.stopMarquee() }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
    }

    public override func layout() {
        super.layout()
        let geometry = TitleFadeGeometry(
            textWidth: text.textWidth, span: bounds.width, visibleWidth: bounds.width,
            leadingPadding: leadingPadding, trailingPadding: 0, fadeWidth: fadeWidth
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.apply(geometry, frame: bounds, animated: false)
        CATransaction.commit()
    }
}
