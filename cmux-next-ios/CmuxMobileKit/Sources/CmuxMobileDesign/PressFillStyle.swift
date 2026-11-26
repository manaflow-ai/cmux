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
    /// The fill's corner, for the `.rounded` shape.
    public var cornerRadius: CGFloat
    /// The label takes the tint (what `.borderless` drew), not the primary label color.
    public var tinted: Bool
    /// The fill's shape: the label's own shape, so a circle or capsule never shows a square wash.
    public var shape: CmuxMobilePressShape

    public init(rest: Color? = nil, pressed: Color? = nil, cornerRadius: CGFloat = 8, tinted: Bool = false,
                shape: CmuxMobilePressShape = .rounded) {
        self.rest = rest
        self.pressed = pressed
        self.cornerRadius = cornerRadius
        self.tinted = tinted
        self.shape = shape
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A custom style's label takes the tint where nothing sets its color; `.plain` drew it in the primary
            // label color, `.borderless` in the tint. A color set on the button from outside still wins.
            .tint(tinted ? nil : Color.primary)
            .modifier(PressFillShape(isPressed: configuration.isPressed, rest: rest, pressed: pressed,
                                     cornerRadius: cornerRadius, shape: shape))
            .environment(\.cmuxMobileIsPressed, configuration.isPressed)
    }
}

/// The shape of ``CmuxMobilePressFillStyle``'s fill. A button whose label is a circle, a capsule or a glass disc
/// names it here; `scripts/cmux-next/check-pressed-state.py` refuses the default `.rounded` on those labels.
public enum CmuxMobilePressShape: Sendable {
    /// A continuous rounded rectangle with the style's `cornerRadius` (the default).
    case rounded
    case circle
    case capsule
    /// No wash: the label is interactive Liquid Glass (`.glassEffect(... .interactive())`), whose own press
    /// response is the pressed look. The label still never dims or changes.
    case glass
    /// The label draws its own fill with ``SwiftUI/View/cmuxMobilePressBackground(_:in:)`` exactly where its
    /// shape is (a 22 pt badge in a 44 pt target, a filled disc, a chip); the style only tells it when it is held.
    case label
    /// No wash: the label is a line of bare text on the page (a transcript disclosure: a thought, a tool call,
    /// a tool group, "Worked for"). A fill behind bare text draws a gray box out of nothing (Leo 2026-11-23,
    /// on tapping a thought, paraphrased: it had that square placeholder backing, "THAT AINT RIGHT"). The
    /// tap's answer is the chevron turning and the body opening, as the drawn (UIKit) rows of the same lines do.
    case line
}

extension EnvironmentValues {
    /// True while the ``CmuxMobilePressFillStyle`` button around this view is held.
    @Entry public var cmuxMobileIsPressed: Bool = false
}

private struct PressFillShape: ViewModifier {
    let isPressed: Bool
    let rest: Color?
    let pressed: Color?
    let cornerRadius: CGFloat
    let shape: CmuxMobilePressShape

    func body(content: Content) -> some View {
        let rest = rest.map { AnyShapeStyle($0) }
        switch shape {
        case .rounded:
            content.cmuxMobilePressFill(isPressed, rest: rest, pressed: pressed,
                                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .circle:
            content.cmuxMobilePressFill(isPressed, rest: rest, pressed: pressed, in: Circle())
        case .capsule:
            content.cmuxMobilePressFill(isPressed, rest: rest, pressed: pressed, in: Capsule())
        case .glass, .label, .line:
            content.cmuxMobilePressFill(false, rest: rest, pressed: pressed, in: Circle())
        }
    }
}

extension ButtonStyle where Self == CmuxMobilePressFillStyle {
    /// ``CmuxMobilePressFillStyle``: no fill at rest, the pressed wash while held, the label unchanged.
    public static var cmuxPressFill: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle() }
    /// ``cmuxPressFill`` with the label in the tint, as `.borderless` drew it.
    public static var cmuxPressFillTinted: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(tinted: true) }
    /// ``cmuxPressFill`` for a circular label: the wash is a circle the size of the label's frame.
    public static var cmuxPressFillCircle: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(shape: .circle) }
    /// ``cmuxPressFill`` for a capsule label: the wash is a capsule the size of the label's frame.
    public static var cmuxPressFillCapsule: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(shape: .capsule) }
    /// For an interactive Liquid Glass label: no wash (the glass's own press is the look), the label unchanged.
    public static var cmuxPressGlass: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(shape: .glass) }
    /// The label draws the fill and its wash itself, with ``SwiftUI/View/cmuxMobilePressBackground(_:in:)``.
    public static var cmuxPressFillInLabel: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(shape: .label) }
    /// For a line of bare text on the page (a transcript disclosure): no wash, the label unchanged.
    public static var cmuxPressLine: CmuxMobilePressFillStyle { CmuxMobilePressFillStyle(shape: .line) }
}

extension View {
    /// A button label's own fill under ``CmuxMobilePressFillStyle/cmuxPressFillInLabel``: `rest` in `shape`, with
    /// the pressed wash over it while the button is held. Use it in place of `.background(rest, in: shape)`.
    public func cmuxMobilePressBackground<S: Shape>(_ rest: some ShapeStyle, in shape: S) -> some View {
        modifier(PressBackground(rest: AnyShapeStyle(rest), shape: shape))
    }

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
private struct PressBackground<S: Shape>: ViewModifier {
    let rest: AnyShapeStyle
    let shape: S
    @Environment(\.cmuxMobileIsPressed) private var isPressed

    func body(content: Content) -> some View {
        content.cmuxMobilePressFill(isPressed, rest: rest, in: shape)
    }
}
#endif
