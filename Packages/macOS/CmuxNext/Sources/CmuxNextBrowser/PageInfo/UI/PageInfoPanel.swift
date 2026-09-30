import AppKit
import CmuxNextDesign

/// The bubble's window: a borderless child panel of the browser window, so
/// it draws above Chromium page windows (which are child windows too) and
/// moves with the window. It takes key status for keyboard navigation and
/// closes when it loses it (a click outside, another window, the anchor).
final class PageInfoPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeStore.shared.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = true
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.pageInfo")
        setAccessibilityRole(.popover)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// Glass card that hosts one page and reports the size it needs.
final class PageInfoCardView: NSView {
    private let glass = Glass.makePanel(cornerRadius: PageInfoStyle.cornerRadius)
    private let body = OverlayBackingView()
    private var content: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.contentView = body
        body.wantsLayer = true
        addSubview(glass)
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = Palette.shadow.withAlphaComponent(0.24)
            shadow.shadowBlurRadius = PageInfoStyle.shadowMargin * 0.6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card holds focus when the bubble opens (no row ring until Tab).
    override var acceptsFirstResponder: Bool { true }

    /// Replaces the page; returns the card size it needs at the bubble width.
    func setContent(_ view: NSView) -> CGSize {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        let inset = PageInfoStyle.inset
        let width = PageInfoStyle.bubbleWidth
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset / 2),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset / 2),
            view.topAnchor.constraint(equalTo: body.topAnchor, constant: inset / 2),
            view.widthAnchor.constraint(equalToConstant: width - inset),
        ])
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height + inset
        return CGSize(width: width, height: ceil(height))
    }

    override func layout() {
        super.layout()
        let margin = PageInfoStyle.shadowMargin
        glass.frame = bounds.insetBy(dx: margin, dy: margin)
    }
}
