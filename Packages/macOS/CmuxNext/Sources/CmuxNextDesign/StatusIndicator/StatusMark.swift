/// One drawn mark of a status icon set (`StatusIconSet`), as a value: a
/// figure alone, a figure knocked out of a filled container (a badge), a
/// figure inside a stroked container, a monogram, or an SF Symbol.
/// `StatusMarkArt` draws it as an alpha mask the indicator tints with a theme
/// role, so every mark takes the theme's colors in light and dark.
public nonisolated enum StatusMark: Hashable, Sendable {
    /// The figure alone, filling the slot.
    case glyph(Figure)
    /// A filled container with the figure cut out (nil: solid).
    case badge(Container, Figure?)
    /// A stroked container with the figure inside (nil: empty).
    case outline(Container, Figure?)
    /// A letter cut out of a filled rounded square.
    case letter(String)
    /// An SF Symbol, drawn as a template.
    case symbol(String)

    public enum Container: Hashable, Sendable {
        case circle, roundedSquare, triangle, octagon
    }

    public enum Figure: Hashable, Sendable {
        case exclamation, question, key, check, cross, hand, shield, bubble, bubbleQuestion, sparkle, dot, pip, hollowPip, diamond
    }
}
