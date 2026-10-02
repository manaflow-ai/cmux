public import AppKit

/// Behind-window vibrancy under chrome (the sidebar, the tab strips), with
/// a theme color laid over it so the chrome still reads as the theme.
/// Content (terminals, pages) never sits on it.
///
/// The material stays active whether or not the window is key, so the
/// chrome never changes color on its own, and it takes its light or dark
/// appearance from the view's theme scope. The blur shows only where the
/// window is see-through (`WindowBackdrop(tokens)`, from the resolved
/// opacity) and Reduce Transparency is off; otherwise the chrome is the
/// solid theme color, as before vibrancy.
public final class ChromeBackdropView: NSView {
    /// How much the theme color covers the blur. Modest: the desktop shows
    /// through only faintly; the terminal's background-opacity is the
    /// user's control for more.
    public static let defaultTintOpacity: CGFloat = 0.82

    /// The theme color over the blur, read inside this view's scope.
    public var tint: @MainActor () -> NSColor { didSet { applyTheme() } }
    public var tintOpacity: CGFloat { didSet { applyTheme() } }
    /// Whether Reduce Transparency is on (tests pin it; the host setting
    /// differs between machines).
    var reduceTransparency: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency } {
        didSet { applyTheme() }
    }
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyTheme()
    }

    /// True while the blur shows (tests read it).
    var showsBlur: Bool { !effect.isHidden }
    /// The color laid over the blur (tests read it).
    var tintColor: CGColor? { tintView.layer?.backgroundColor }

    @objc private func displayOptionsChanged() {
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
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            let solid = WindowBackdrop(tokens).isOpaque || reduceTransparency()
            effect.isHidden = solid
            let color = tint()
            tintView.layer?.backgroundColor = color.withAlphaComponent(solid ? color.alphaComponent : color.alphaComponent * tintOpacity).cgColor
        }
    }
}
