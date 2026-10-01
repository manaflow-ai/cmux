#if canImport(UIKit)
public import UIKit

extension TerminalSizingPalette {
    public func uiColor(_ role: Role) -> UIColor {
        rgb(role).uiColor
    }

    /// The palette of two UIKit colors, resolved for `traits`. A translucent
    /// foreground composites over the background.
    public init(background: UIColor, foreground: UIColor, traits: UITraitCollection) {
        let surface = RGB(background.resolvedColor(with: traits), over: RGB(red: 0, green: 0, blue: 0))
        self.init(background: surface, foreground: RGB(foreground.resolvedColor(with: traits), over: surface))
    }

    /// A dynamic color for `role` that re-derives the palette from
    /// `background` and `foreground` in each trait environment (light, dark,
    /// increased contrast).
    public static func dynamicColor(_ role: Role, background: UIColor, foreground: UIColor) -> UIColor {
        UIColor { traits in
            TerminalSizingPalette(background: background, foreground: foreground, traits: traits).uiColor(role)
        }
    }
}

extension TerminalSizingPalette.RGB {
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// `color` in sRGB, clamped, composited over `base` when translucent.
    init(_ color: UIColor, over base: Self) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            color.getWhite(&white, alpha: &alpha)
            red = white; green = white; blue = white
        }
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        let own = Self(red: clamp(red), green: clamp(green), blue: clamp(blue))
        self = alpha >= 0.999 ? own : base.mixed(toward: own, by: Double(alpha))
    }
}
#endif
