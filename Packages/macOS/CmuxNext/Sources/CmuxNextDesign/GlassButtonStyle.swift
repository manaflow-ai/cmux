public import SwiftUI
public import CmuxNextDesignTokens

extension View {
    /// The Liquid Glass button style (`.glass`, macOS 26 and later), or
    /// `.bordered` where Liquid Glass is missing
    /// (`Glass.isLiquidGlassAvailable`). It shows the arrow, as native buttons do.
    @ViewBuilder
    public func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), Glass.isLiquidGlassAvailable {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// The pressed look lives beside the glass style: macOS adds no new SwiftUI files (check-no-swiftui.py).
/// The one pressed look for a SwiftUI button in cmux NEXT: while it is held the label stays exactly as it is
/// (no bold, no other font or size, no scale, no dimming) and only the fill behind it changes (DESIGN.md
/// "Pressed state", Lawrence 2026-11-15: "we only want to have different bg color on mousedown").
///
/// SwiftUI's own `.plain`, `.borderless` and `.link` styles dim the label while it is held, so cmux uses this
/// style instead; `scripts/cmux-next/check-pressed-state.py` refuses them. AppKit chrome gets the same look from
/// ``ChromeHover`` (`ChromeHover.State(pressed:)` picks `Palette.pressedFill`).
///
/// On a menu or popover's glass (`cmuxOnMenuGlass(_:)` on the content) a label that takes its ink from the button draws
/// the theme's text fit to that glass (``GlassMenuMaterial/ink(_:tokens:minimum:)``), not the ink fit to the opaque page:
/// Hot Dog Stand's Rename read 4.16:1 over a black page. A label that sets its own ink keeps it.
public struct CmuxPressFillButtonStyle: ButtonStyle {
    /// The theme of the menu glass the button sits on (`cmuxOnMenuGlass(_:)`), else nil.
    @Environment(\.cmuxMenuGlass) private var menuGlass

    /// The fill at rest (and under the pointer); nil draws none.
    public var rest: Color?
    /// The fill while held; nil is `Palette.pressedFill`.
    public var pressed: Color?
    /// The fill's corner; nil is `Metrics.buttonCornerRadius`.
    public var cornerRadius: CGFloat?
    /// The fill's shape: the label's own shape, so a circle or capsule never shows a square wash.
    public var shape: CmuxPressShape

    public init(rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat? = nil, shape: CmuxPressShape = .rounded) {
        self.rest = rest
        self.pressed = pressed
        self.cornerRadius = cornerRadius
        self.shape = shape
    }

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        let fill = configuration.isPressed ? (pressed ?? Color(nsColor: Palette.pressedFill)) : rest
        switch shape {
        case .rounded:
            configuration.label.modifier(MenuGlassInk(tokens: menuGlass))
                .cmuxPressFill(configuration.isPressed, rest: rest, pressed: pressed, cornerRadius: cornerRadius)
        case .circle:
            configuration.label.modifier(MenuGlassInk(tokens: menuGlass)).background(fill ?? Color.clear, in: Circle()).contentShape(Circle())
        case .capsule:
            configuration.label.modifier(MenuGlassInk(tokens: menuGlass)).background(fill ?? Color.clear, in: Capsule()).contentShape(Capsule())
        case .glass:
            // Interactive Liquid Glass answers the press itself; only the rest fill is drawn.
            configuration.label.modifier(MenuGlassInk(tokens: menuGlass)).background(rest ?? Color.clear, in: Circle())
        }
    }
}

/// The theme's text fit to the menu glass of `tokens` as the ink a label inherits; no change off menu glass.
private struct MenuGlassInk: ViewModifier {
    let tokens: ThemeTokens?

    func body(content: Content) -> some View {
        if let tokens {
            content.foregroundStyle(GlassMenuMaterial.ink(\.textPrimary, tokens: tokens).swiftUIColor)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// The theme of the menu or popover glass this content sits on (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``),
    /// set with `cmuxOnMenuGlass(_:)`; nil on a window or a sheet. ``CmuxPressFillButtonStyle`` fits its ink to it.
    @Entry public var cmuxMenuGlass: ThemeTokens?
}

extension View {
    /// Marks this content as drawn on a menu or popover's glass in the theme `tokens`, so its buttons fit their inks to
    /// that glass over any page (``CmuxPressFillButtonStyle``). Set it on the root of SwiftUI content a menu panel hosts.
    ///
    /// ```swift
    /// FirstMouseHostingView(rootView: BrowserDownloadsPopupView(model: model).cmuxOnMenuGlass(tokens))
    /// ```
    public func cmuxOnMenuGlass(_ tokens: ThemeTokens?) -> some View {
        environment(\.cmuxMenuGlass, tokens)
    }
}

/// The shape of ``CmuxPressFillButtonStyle``'s fill. A button whose label is a circle, a capsule or a glass disc
/// names it here; `scripts/cmux-next/check-pressed-state.py` refuses the default `.rounded` on those labels.
public enum CmuxPressShape: Sendable {
    /// A continuous rounded rectangle with the style's corner (the default).
    case rounded
    case circle
    case capsule
    /// No wash: the label is interactive Liquid Glass, whose own press response is the pressed look.
    case glass
}

extension ButtonStyle where Self == CmuxPressFillButtonStyle {
    /// ``CmuxPressFillButtonStyle`` with no fill at rest and `Palette.pressedFill` while held.
    public static var cmuxPressFill: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle() }
    /// ``cmuxPressFill`` for a circular label.
    public static var cmuxPressFillCircle: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle(shape: .circle) }
    /// ``cmuxPressFill`` for a capsule label.
    public static var cmuxPressFillCapsule: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle(shape: .capsule) }
    /// For an interactive Liquid Glass label: no wash, the label unchanged.
    public static var cmuxPressGlass: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle(shape: .glass) }
}

extension View {
    /// The pressed look of ``CmuxPressFillButtonStyle`` for a style that sets its own font, ink and padding
    /// first: the fill behind the label is `pressed` while `isPressed`, else `rest`; nothing else changes.
    public func cmuxPressFill(_ isPressed: Bool, rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat? = nil) -> some View {
        let fill = isPressed ? (pressed ?? Color(nsColor: Palette.pressedFill)) : rest
        return background(fill ?? Color.clear,
                          in: RoundedRectangle(cornerRadius: cornerRadius ?? Metrics.buttonCornerRadius, style: .continuous))
            .contentShape(Rectangle())
    }
}
