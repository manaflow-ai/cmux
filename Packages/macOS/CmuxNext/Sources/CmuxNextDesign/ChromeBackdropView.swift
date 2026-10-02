public import AppKit

/// Behind-window vibrancy under chrome (the sidebar, the tab strips), with
/// a theme color laid over it so the chrome still reads as the theme.
/// Content (terminals, pages) never sits on it.
///
/// The material stays active whether or not the window is key, so the
/// chrome never changes color on its own, and it takes its light or dark
/// appearance from the view's theme scope. With Reduce Transparency AppKit
/// draws the material solid; the tint still carries the theme color.
public final class ChromeBackdropView: NSView {
    /// How much the theme color covers the blur. Modest: the desktop shows
    /// through only faintly; the terminal's background-opacity is the
    /// user's control for more.
    public static let defaultTintOpacity: CGFloat = 0.82

    /// The theme color over the blur, read inside this view's scope.
    public var tint: @MainActor () -> NSColor { didSet { applyTheme() } }
    public var tintOpacity: CGFloat { didSet { applyTheme() } }
    private let effect = NSVisualEffectView()
    private let tintView = NSView()

    public init(material: NSVisualEffectView.Material, tintOpacity: CGFloat = ChromeBackdropView.defaultTintOpacity, tint: @escaping @MainActor () -> NSColor) {
        self.tint = tint
        self.tintOpacity = tintOpacity
        super.init(frame: .zero)
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        tintView.wantsLayer = true
        for view in [effect, tintView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        setAccessibilityElement(false)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Decoration only: clicks reach the chrome above or the window.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            let color = tint()
            tintView.layer?.backgroundColor = color.withAlphaComponent(color.alphaComponent * tintOpacity).cgColor
        }
    }
}
