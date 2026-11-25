public import SwiftUI

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
public struct CmuxPressFillButtonStyle: ButtonStyle {
    /// The fill at rest (and under the pointer); nil draws none.
    public var rest: Color?
    /// The fill while held; nil is `Palette.pressedFill`.
    public var pressed: Color?
    /// The fill's corner; nil is `Metrics.buttonCornerRadius`.
    public var cornerRadius: CGFloat?

    public init(rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat? = nil) {
        self.rest = rest
        self.pressed = pressed
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.cmuxPressFill(configuration.isPressed, rest: rest, pressed: pressed, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == CmuxPressFillButtonStyle {
    /// ``CmuxPressFillButtonStyle`` with no fill at rest and `Palette.pressedFill` while held.
    public static var cmuxPressFill: CmuxPressFillButtonStyle { CmuxPressFillButtonStyle() }
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
