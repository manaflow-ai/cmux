#if os(iOS)
public import SwiftUI

/// The one pressed look for a cmux-next iPhone button: while it is held the label stays exactly as it is
/// (no bold, no other font or size, no scale, no dimming) and only the fill behind it changes (DESIGN.md
/// "Pressed state", Lawrence 2026-11-15: "we only want to have different bg color on mousedown"). The Mac's
/// twin is `CmuxPressFillButtonStyle` (CmuxNextDesign).
///
/// SwiftUI's own `.plain`, `.borderless` and `.link` styles dim the label while it is held, so cmux uses
/// this style instead; `scripts/cmux-next/check-pressed-state.py` refuses them.
public struct CmuxMobilePressFillStyle: ButtonStyle {
    /// The fill at rest; nil draws none.
    public var rest: Color?
    /// The wash laid over `rest` while held; nil is `Color.cmuxMobileFillPressed`.
    public var pressed: Color?
    /// The fill's corner.
    public var cornerRadius: CGFloat
    /// The label takes the tint (what `.borderless` drew), not the primary label color.
    public var tinted: Bool

    public init(rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat = 8, tinted: Bool = false) {
        self.rest = rest
        self.pressed = pressed
        self.cornerRadius = cornerRadius
        self.tinted = tinted
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A custom style's label takes the tint where nothing sets its color; `.plain` drew it in the primary
            // label color, `.borderless` in the tint. A color set on the button from outside still wins.
            .tint(tinted ? nil : Color.primary)
            .cmuxMobilePressFill(configuration.isPressed, rest: rest.map { AnyShapeStyle($0) }, pressed: pressed,
                                 in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == CmuxMobilePressFillStyle {
    /// ``CmuxMobilePressFillStyle``: no fill at rest, the pressed wash while held, the label unchanged.
    public static var cmuxPressFill: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle() }
    /// ``cmuxPressFill`` with the label in the tint, as `.borderless` drew it.
    public static var cmuxPressFillTinted: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(tinted: true) }
}

extension View {
    /// The pressed look of ``CmuxMobilePressFillStyle`` for a style that sets its own font, ink and padding
    /// first: `rest` behind the label, with the pressed wash over it while `isPressed`. Nothing else changes.
    public func cmuxMobilePressFill<S: Shape>(_ isPressed: Bool, rest: AnyShapeStyle? = nil, pressed: Color? = nil, in shape: S) -> some View {
        background {
            ZStack {
                if let rest { shape.fill(rest) }
                shape.fill(pressed ?? Color.cmuxMobileFillPressed).opacity(isPressed ? 1 : 0)
            }
        }
    }
}
#endif
