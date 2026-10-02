/// What draws behind a cmux window's content: the one material the whole
/// window shares (the terminal, panes, the agent pane and chrome stay clear
/// over it).
///
/// ``WindowBackdrop`` decides it from the resolved `background-opacity`,
/// `background-blur` and Reduce Transparency.
public nonisolated enum WindowMaterial: Hashable, Sendable {
    /// The two Liquid Glass styles Ghostty's `background-blur` names.
    public nonisolated enum GlassStyle: Hashable, Sendable {
        /// `macos-glass-regular`: the standard frosted glass.
        case regular
        /// `macos-glass-clear`: the more see-through glass.
        case clear
    }

    /// No material: the window and its root paint the theme background
    /// solid. An opaque background, or Reduce Transparency.
    case opaque
    /// Liquid Glass (`NSGlassEffectView`) in the given style, for Ghostty's
    /// `background-blur = macos-glass-regular` (-1) or
    /// `macos-glass-clear` (-2).
    case glass(GlassStyle)
    /// The theme tint over the desktop, blurred by the window's own
    /// `background-blur` radius (`WindowBlurRadius`, the CGS blur
    /// Ghostty.app uses): a translucent window with a radius, or
    /// `appearance.backgroundBlur = "frosted"`. No view: a window-sized
    /// behind-window `NSVisualEffectView` composites the desktop and its own
    /// material into an opaque sheet, so the window read as opaque.
    case frosted
    /// Plain see-through: no material view, only the theme tint at the
    /// resolved opacity. A translucent window with no blur
    /// (`background-blur = false`, or `appearance.backgroundBlur = "none"`).
    case translucent

    /// Whether the window root hosts a material view for this material.
    public var hasMaterialView: Bool {
        switch self {
        case .glass: true
        case .opaque, .translucent, .frosted: false
        }
    }
}
