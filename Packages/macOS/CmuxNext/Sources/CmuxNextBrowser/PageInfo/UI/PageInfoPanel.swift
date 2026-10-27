import AppKit
import CmuxNextDesign

/// The bubble's window: a popup of the shared native host (``NativePopupHost``, hq REUSE.md
/// slice 3), a borderless child panel of the browser window in the popup style, so it draws above
/// Chromium page windows and moves with the window. It takes the keys for keyboard navigation
/// (only while the app is active); the host closes it when it loses them, on a click outside, on
/// Escape and when the app or the window goes away.
final class PageInfoPanel: NativePopupPanel {
    var onKey: ((NSEvent) -> Bool)?

    init() {
        super.init(identifier: "cmux.pageInfo")
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// Glass card that hosts one page and reports the size it needs. The host draws the popup shadow
/// around it (``PopupHostView``).
final class PageInfoCardView: NSView {
    private let body: OverlayBackingView
    /// The card's material: glass, or opaque under Reduce Transparency.
    let glass: OverlaySurfaceView
    private var content: NSView?

    override init(frame: NSRect) {
        let body = OverlayBackingView()
        self.body = body
        glass = Glass.makeOverlayPanel(content: body, cornerRadius: PageInfoStyle.cornerRadius)
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        body.wantsLayer = true
        addSubview(glass)
        applyColors()
    }

    // visibility-walk-allow: the glass tint of the bubble's own panel, which no tab node holds (it is ordered out while closed); a few color stores, no layout
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The glass tint of the bubble's theme scope (the panel adopts the omnibar's scope when it
    /// opens).
    private func applyColors() {
        performWithTheme { glass.applyTheme() }
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
        // sync-layout: fittingSize below measures the page at the bubble width (its labels wrap).
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height + inset
        return CGSize(width: width, height: ceil(height))
    }
}
