/// Where two colors blend in a color transition (`appearance.colorTransition.colorSpace`). The
/// mix itself is cmux-motion's (`mix_rgba`, through the app FFI on macOS).
public enum ThemeColorSpace: String, Sendable, Hashable, CaseIterable {
    /// Perceptual: lightness moves evenly, so two hues never pass through a muddy or dark middle.
    case oklab
    /// The plain channel mix (what browsers do for legacy `rgb()` colors).
    case srgb
}
