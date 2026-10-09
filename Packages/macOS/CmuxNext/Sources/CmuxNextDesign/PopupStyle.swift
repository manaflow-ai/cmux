public import AppKit

/// One look for every native popover and menu (hover cards, group editors,
/// the icon picker, page info, the palette's actions menu): the web's popup
/// surface (webviews/src/ui/popupSurface.css, #18729) in AppKit. Small-radius
/// rects, compact rows and one subtle shadow; each surface keeps its own
/// material and theme colors. `PopupStyleTests` holds the two in step.
public enum PopupStyle {
    public static let cornerRadius: CGFloat = 8
    public static let padding: CGFloat = 4
    public static let rowHeight: CGFloat = 28
    public static let rowCornerRadius: CGFloat = 5
    public static let rowPaddingInline: CGFloat = 8
    public static let openDuration: TimeInterval = 0.12

    /// The one shadow, `0 2px 8px` black at 12%.
    public static let shadowOffset: CGFloat = 2
    public static let shadowBlur: CGFloat = 8
    public static let shadowAlpha: CGFloat = 0.12

    /// The transparent band a popover window keeps around its card, so the
    /// card's shadow is never clipped by the window.
    public static var shadowMargin: CGFloat { shadowBlur + shadowOffset }

    /// The card's shadow (AppKit's offset is y-up: negative falls below).
    public static func shadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
        return shadow
    }

    /// The window frame for a card at `card` (screen coordinates).
    public static func windowFrame(forCard card: CGRect) -> CGRect {
        card.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }

    /// The card's frame in a popover window at `window`.
    public static func cardFrame(inWindow window: CGRect) -> CGRect {
        window.insetBy(dx: shadowMargin, dy: shadowMargin)
    }
}

/// A popover window's content view: its card inset by
/// `PopupStyle.shadowMargin`, casting the popup shadow into that band. The
/// window draws no shadow of its own and stays clear around the card; a
/// pointer in the band reaches whatever is under it.
@MainActor
public final class PopupHostView: NSView {
    public let card: NSView

    /// `card` sizes by its frame (the host lays it out). An
    /// `OverlaySurfaceView` card takes the popup radius.
    public init(card: NSView) {
        self.card = card
        super.init(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = true
        card.wantsLayer = true
        if let surface = card as? OverlaySurfaceView { surface.cornerRadius = PopupStyle.cornerRadius }
        card.shadow = PopupStyle.shadow()
        addSubview(card)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeCard()
    }

    public override func layout() {
        super.layout()
        placeCard()
    }

    private func placeCard() {
        card.frame = bounds.insetBy(dx: PopupStyle.shadowMargin, dy: PopupStyle.shadowMargin)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        card.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
}

extension NSPanel {
    /// Makes `card` this popover's content, in the popup style: no window
    /// shadow, a clear window, the card in a `PopupHostView`.
    @MainActor
    @discardableResult
    public func adoptPopupStyle(card: NSView) -> PopupHostView {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        let host = PopupHostView(card: card)
        contentView = host
        return host
    }
}
