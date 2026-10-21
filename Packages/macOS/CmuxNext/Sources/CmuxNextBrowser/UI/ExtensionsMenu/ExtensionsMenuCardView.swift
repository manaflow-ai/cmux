import AppKit
import CmuxNextDesign

/// The bubble's card: the theme's glass at Chrome's 12-point radius, hosting the content edge to
/// edge. The host draws the popup shadow around it (``PopupHostView``).
final class ExtensionsMenuCardView: NSView {
    let glass: OverlaySurfaceView
    let content: ExtensionsMenuView

    init(content: ExtensionsMenuView, style: ExtensionsMenuStyle = .chrome) {
        self.content = content
        glass = Glass.makeOverlayPanel(content: content, cornerRadius: style.cornerRadius)
        super.init(frame: content.frame)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The glass tint of the bubble's theme scope (the panel adopts the toolbar's scope).
    private func applyColors() {
        performWithTheme { glass.applyTheme() }
    }

    /// The card holds the keys when the bubble opens (no row highlighted until an arrow key).
    override var acceptsFirstResponder: Bool { true }
}
