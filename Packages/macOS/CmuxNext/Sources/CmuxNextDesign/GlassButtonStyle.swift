public import SwiftUI
import CmuxNextWakeups
import CmuxTheme

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
/// On a menu panel's glass (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``) a label that takes its ink from
/// the button draws the theme's text fit to that glass (``GlassMenuMaterial/ink(_:tokens:minimum:)``), not the ink fit to
/// the opaque page: Hot Dog Stand's Rename read 4.16:1 over a black page. The button finds the panel in the view tree
/// (``MenuGlassProbeView``), so content a menu panel hosts sets no mark. A label that sets its own ink keeps it.
public struct CmuxPressFillButtonStyle: ButtonStyle {
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

    public func makeBody(configuration: Configuration) -> some View {
        PressFillBody(configuration: configuration, style: self)
    }
}

/// ``CmuxPressFillButtonStyle``'s button: the label on its fill, in the menu glass ink while it sits on a menu panel.
private struct PressFillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: CmuxPressFillButtonStyle
    /// The theme of the menu panel's glass the button sits on, read from the view tree; nil off menu glass.
    @State private var menuGlass: ThemeTokens?

    var body: some View {
        shaped.background(MenuGlassProbe(menuGlass: $menuGlass))
    }

    @ViewBuilder
    private var shaped: some View {
        let label = configuration.label.modifier(MenuGlassInk(tokens: menuGlass))
        let fill = configuration.isPressed ? (style.pressed ?? Color(nsColor: Palette.pressedFill)) : style.rest
        switch style.shape {
        case .rounded:
            label.cmuxPressFill(configuration.isPressed, rest: style.rest, pressed: style.pressed, cornerRadius: style.cornerRadius)
        case .circle:
            label.background(fill ?? Color.clear, in: Circle()).contentShape(Circle())
        case .capsule:
            label.background(fill ?? Color.clear, in: Capsule()).contentShape(Capsule())
        case .glass:
            // Interactive Liquid Glass answers the press itself; only the rest fill is drawn.
            label.background(style.rest ?? Color.clear, in: Circle())
        }
    }
}

/// Hosts a ``MenuGlassProbeView`` behind the button and keeps `menuGlass` to what it finds.
private struct MenuGlassProbe: NSViewRepresentable {
    let menuGlass: Binding<ThemeTokens?>

    func makeNSView(context: Context) -> MenuGlassProbeView {
        let probe = MenuGlassProbeView(frame: .zero)
        updateNSView(probe, context: context)
        return probe
    }

    func updateNSView(_ probe: MenuGlassProbeView, context: Context) {
        let menuGlass = menuGlass
        // The probe reports from AppKit's view-tree callbacks, which can run inside SwiftUI's own update (a probe made
        // in a window moves to it there): the state is written once that pass committed its frame, never during it.
        probe.onChange = { tokens in AfterFrameCommit().run { menuGlass.wrappedValue = tokens } }
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
