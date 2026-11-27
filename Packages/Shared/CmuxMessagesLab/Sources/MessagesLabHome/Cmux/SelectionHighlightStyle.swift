import AppKit

/// cmux: how the transcript's text-selection highlight (RowCell.selectionHighlight) draws over the surface under it.
///
/// MessagesLab's highlight is one fill, P3 (2.6, 37.7, 85), screen-blended: measured on Messages' dark incoming
/// bubble (59, 59, 61) it gives Messages' highlight (61, 88, 126). A screen blend only lightens, so on a light
/// surface (the light appearance's white page and 233/233/235 bubble, a light theme, a light sent bubble) it draws
/// almost nothing: about 1.0:1 against the surface, and the person sees no selection (issue 38145). On those the
/// highlight multiplies the light selection blue (179, 215, 255) instead, which only darkens: the system's own
/// light selection over white, and the text under it stays as dark as it was.
///
/// Each row picks the blend that stands out more from its own bubble (`style(on:)`), so a dark bubble keeps
/// Messages' measured look and every light one gets a visible highlight. A sent bubble is judged by its theme's
/// first gradient stop (`Fixture.outgoing`); the live gradient shifts with the row's window position, so a theme
/// whose stops run from light to dark can get the weaker of the two blends far from that stop.
struct SelectionHighlightStyle: Equatable {
    enum Blend: String, Equatable {
        case screen = "screenBlendMode"
        case multiply = "multiplyBlendMode"
    }

    /// Display P3 components, 0...1.
    struct RGB: Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat
    }

    var fill: RGB
    var blend: Blend

    /// MessagesLab's measured dark highlight (screen blend).
    static let screen = SelectionHighlightStyle(fill: RGB(r: 2.6 / 255, g: 37.7 / 255, b: 85 / 255), blend: .screen)
    /// The light selection blue (multiply blend): over white it is the system's light text selection.
    static let multiply = SelectionHighlightStyle(fill: RGB(r: 179 / 255, g: 215 / 255, b: 1), blend: .multiply)

    /// The least WCAG 2 contrast a highlight keeps from the neutral surface under it (HIGHLIGHT-CONTRAST's selection
    /// floor in the webviews, webviews/src/ui/highlightContrast.ts).
    static let surfaceFloor: CGFloat = 1.3

    /// The style that stands out more from `surface`; screen (Messages' own) when they tie.
    static func style(on surface: RGB) -> SelectionHighlightStyle {
        contrast(multiply.composite(over: surface), surface) > contrast(screen.composite(over: surface), surface) ? multiply : screen
    }

    static func style(on surface: NSColor) -> SelectionHighlightStyle {
        style(on: components(surface) ?? RGB(r: 0, g: 0, b: 0))
    }

    /// What the highlight shows over an opaque `surface`.
    func composite(over surface: RGB) -> RGB {
        func mix(_ f: CGFloat, _ s: CGFloat) -> CGFloat {
            switch blend {
            case .screen: return 1 - (1 - f) * (1 - s)
            case .multiply: return f * s
            }
        }
        return RGB(r: mix(fill.r, surface.r), g: mix(fill.g, surface.g), b: mix(fill.b, surface.b))
    }

    var cgFill: CGColor { NSColor(displayP3Red: fill.r, green: fill.g, blue: fill.b, alpha: 1).cgColor }

    static func components(_ color: NSColor) -> RGB? {
        guard let p = color.usingColorSpace(.displayP3) else { return nil }
        return RGB(r: p.redComponent, g: p.greenComponent, b: p.blueComponent)
    }

    /// WCAG 2 contrast ratio (the components read as sRGB-encoded, as the webviews' check does).
    static func contrast(_ a: RGB, _ b: RGB) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: RGB) -> CGFloat { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
