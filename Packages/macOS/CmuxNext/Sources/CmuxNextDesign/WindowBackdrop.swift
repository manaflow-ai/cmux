public import CoreGraphics

/// How the window behind the terminal is drawn for the resolved
/// `background-opacity` and `background-blur`: one ``WindowMaterial`` for
/// the whole window with one theme tint over it (only the tint for
/// ``WindowMaterial/translucent``).
///
/// The window is non-opaque for every material other than
/// ``WindowMaterial/opaque``, with a white background at alpha 0.001 (not
/// clear, so it keeps its shadow and hit
/// testing). A frosted window takes its blur as the window's CGS radius
/// (``windowBlurRadius``, 0 for every other material), so only Liquid
/// Glass hosts a material view, which blurs by itself.
///
/// ```swift
/// let backdrop = WindowBackdrop(themeTokens, reduceTransparency: false)
/// window.setBackgroundBlurRadius(backdrop.windowBlurRadius)
/// ```
public nonisolated struct WindowBackdrop: Equatable, Sendable {
    /// The one material behind the window's content.
    public var material: WindowMaterial
    /// Alpha of the theme tint over the material (glass carries it as its
    /// own tint): the resolved
    /// `background-opacity`, or 1 for an opaque window.
    public var tintOpacity: Double
    /// Optional bundled art beneath the material; hidden in opaque mode.
    public var art: BackdropArt? = nil
    /// Optional bundled or system image beneath the material.
    public var selection: BackdropSelection? = nil
    /// Live experimental adjustments applied to the tint.
    public var tuning: AppearanceTuning = .identity
    /// Alpha of the white window background while non-opaque.
    public let windowBackgroundAlpha: CGFloat = 0.001

    /// Whether the window is opaque (no material).
    public var isOpaque: Bool { material == .opaque }
    /// Panes (and the views behind a surface) paint the background only in
    /// an opaque window. Over a material the root's tint is the one
    /// translucent sheet and every layer above it stays clear, so the
    /// terminal shows the background at the configured opacity once.
    public var panesPaintBackground: Bool { isOpaque }
    /// The behind-window blur radius the window takes for this backdrop
    /// (``NSWindow/setBackgroundBlurRadius(_:)``): frosted's own `background-blur` radius, and
    /// 0 for every other material, which clears an earlier frost (glass
    /// blurs in its own view; see-through and opaque have none).
    public let windowBlurRadius: Int

    /// The backdrop for one resolved opacity and blur.
    ///
    /// - Parameter backgroundOpacity: `background-opacity`, 0...1.
    /// - Parameter backgroundBlur: `background-blur` in Ghostty's C
    ///   encoding: 0 off, > 0 radius, -1 `macos-glass-regular`, -2
    ///   `macos-glass-clear`.
    /// - Parameter reduceTransparency: The user's Reduce Transparency
    ///   setting; on, the window is opaque whatever the config says.
    public init(backgroundOpacity: Double, backgroundBlur: Int, reduceTransparency: Bool = false) {
        let opacity = min(max(backgroundOpacity, 0), 1)
        let material: WindowMaterial
        if reduceTransparency {
            material = .opaque
        } else if backgroundBlur == -2 {
            material = .glass(.clear)
        } else if backgroundBlur < 0 {
            material = .glass(.regular)
        } else if opacity < 1 {
            material = backgroundBlur > 0 ? .frosted : .translucent
        } else {
            material = .opaque
        }
        self.material = material
        tintOpacity = material == .opaque ? 1 : opacity
        windowBlurRadius = material == .frosted ? backgroundBlur : 0
    }

    /// The window the tokens' resolved opacity and blur describe: the one
    /// place chrome, panes and the window root read painting from.
    ///
    /// - Parameter tokens: The theme tokens of the view's scope.
    /// - Parameter reduceTransparency: The user's Reduce Transparency setting.
    /// - Parameter art: Bundled art below the window's material and tint.
    public init(_ tokens: ThemeTokens, reduceTransparency: Bool = false, art: BackdropArt? = nil,
                selection: BackdropSelection? = nil, tuning: AppearanceTuning = .identity) {
        let resolvedSelection = selection ?? art.map(BackdropSelection.art)
        let opacity = resolvedSelection == nil || tokens.backgroundOpacity < 1
            ? tokens.backgroundOpacity
            : tokens.wallpaperTintOpacity
        self.init(backgroundOpacity: opacity, backgroundBlur: tokens.backgroundBlur,
                  reduceTransparency: reduceTransparency)
        self.art = art
        self.selection = resolvedSelection
        self.tuning = tuning
    }
}
