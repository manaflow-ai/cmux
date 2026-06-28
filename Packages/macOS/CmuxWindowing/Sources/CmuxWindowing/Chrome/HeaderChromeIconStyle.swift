public import SwiftUI

/// Visual style for header-chrome glyph controls: interaction opacities, glyph
/// color and weight, and the SF Symbol rendering used in the chrome bars.
///
/// A pure style table (constants plus stateless interaction-opacity functions
/// and a glyph factory). It has no instance dimension, so it stays a caseless
/// namespace for the byte-identical lift; value-type redesign deferred.
// lint:allow namespace-type — faithful lift of the pre-existing app-target header-chrome icon-style table; value-type redesign is call-site-changing and deferred to a separate commit.
public enum HeaderChromeIconStyle {
    /// Resting glyph opacity.
    public static let opacity = 0.86
    /// Glyph opacity while hovered.
    public static let hoveredOpacity = 0.96
    /// Glyph opacity while pressed.
    public static let pressedOpacity = 1.0
    /// Glyph opacity while disabled.
    public static let disabledOpacity = 0.34
    /// Glyph font weight.
    public static let weight: Font.Weight = .regular
    /// Glyph foreground color.
    public static let foregroundColor = Color(nsColor: .secondaryLabelColor)
    /// Stroke width for the custom sidebar glyph shape.
    public static let sidebarGlyphStrokeWidth: CGFloat = 1

    /// The icon frame size for a given glyph point size.
    public static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
    }

    /// A monochrome SF Symbol rasterized at the header glyph size.
    public static func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .cmuxSymbolRasterSize(RightSidebarChromeMetrics.headerIconSize, weight: weight)
    }

    /// Foreground opacity for a glyph in the given interaction state.
    public static func foregroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return disabledOpacity }
        if isPressed {
            return pressedOpacity
        }
        if isHovering {
            return hoveredOpacity
        }
        return opacity
    }

    /// Background fill opacity for a control in the given interaction state.
    public static func backgroundOpacity(
        hoverBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return 0 }
        if isPressed {
            return 0.14
        }
        if isHovering {
            return hoverBackground ? 0.09 : 0.07
        }
        return 0
    }

    /// Border stroke opacity for a control in the given interaction state.
    public static func borderOpacity(
        buttonBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return buttonBackground ? 0.04 : 0 }
        if isPressed {
            return 0.11
        }
        if isHovering {
            return 0.07
        }
        return buttonBackground ? 0.05 : 0
    }
}
