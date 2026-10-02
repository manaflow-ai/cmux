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
    /// A behind-window blur (`NSVisualEffectView`, `.behindWindow`,
    /// `.active`): a translucent window with a `background-blur` radius, or
    /// `appearance.backgroundBlur = "frosted"`.
    case frosted
    /// Plain see-through: no material view, only the theme tint at the
    /// resolved opacity. A translucent window with no blur
    /// (`background-blur = false`, or `appearance.backgroundBlur = "none"`).
    case translucent

    /// Whether the window root hosts a material view for this material.
    public var hasMaterialView: Bool {
        switch self {
        case .frosted, .glass: true
        case .opaque, .translucent: false
        }
    }
}
