/// Whether the titlebar controls accessory stays visible at all times or only
/// reveals on hover/popover/shortcut-hint activation.
///
/// A pure value type selecting the visibility policy the controls view applies:
/// ``alwaysVisible`` pins the controls (used by the hidden-titlebar minimal-mode
/// host), while ``onHover`` keeps them hidden until the controls are hovered,
/// the notifications popover is shown, or shortcut hints are active.
public enum TitlebarControlsVisibilityMode {
    /// The controls are always shown.
    case alwaysVisible
    /// The controls reveal only on hover/popover/shortcut-hint activation.
    case onHover
}
