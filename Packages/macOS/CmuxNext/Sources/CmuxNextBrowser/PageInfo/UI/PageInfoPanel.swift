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

/// Glass card under the bubble's React page. The host draws the popup shadow
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

    /// Shows the page's web view over the glass, filling the card; the page reports the height
    /// it needs (``PageInfoController``).
    func setContent(_ view: NSView?) {
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = body.bounds
        body.addSubview(view)
    }
}
