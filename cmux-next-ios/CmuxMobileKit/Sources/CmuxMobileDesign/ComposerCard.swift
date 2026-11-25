#if os(iOS)
public import SwiftUI

/// The one composer card on the iPhone, the agent chat's and the terminal's (Leo, 2026-11-24:
/// "for composer in terminal ones just make it the same composer as the ones in the gui chat.
/// well, unify them and make them better. like the chatgpt and claude composers with proper
/// theming AND liquid glass"). One rounded Liquid Glass card holding one row
/// (``ComposerRowLayout``): `+` at the left, the draft between, Send at the right; a draft that
/// wraps goes above the same controls. Anything over the row (attachments) sits inside the card,
/// on top. Each host fills in its own field and controls; the card's size, radius, glass and the
/// controls' 36 pt circles are the same in both.
public struct ComposerCard<Top: View, Leading: View, Field: View, Trailing: View>: View {
    public var look: ComposerCardLook
    /// One line of the field's font (``ComposerRowLayout``).
    public var lineHeight: CGFloat
    private let top: Top
    private let leading: Leading
    private let field: Field
    private let trailing: Trailing

    public init(look: ComposerCardLook = .app, lineHeight: CGFloat,
                @ViewBuilder top: () -> Top,
                @ViewBuilder leading: () -> Leading,
                @ViewBuilder field: () -> Field,
                @ViewBuilder trailing: () -> Trailing) {
        self.look = look
        self.lineHeight = lineHeight
        self.top = top()
        self.leading = leading()
        self.field = field()
        self.trailing = trailing()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: ComposerCardMetrics.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            top
            ComposerRowLayout(lineHeight: lineHeight) {
                leading
                field
                trailing
            }
            .padding(.horizontal, ComposerCardMetrics.rowInset)
            // CMUX-46: the one-line card is the 44 pt row plus 2 pt each side, 48 pt: a true
            // capsule at its 24 pt radius, the 36 pt circles 6 pt in from its edge (concentric).
            .padding(.vertical, ComposerCardMetrics.rowVerticalInset)
        }
        .frame(minHeight: ComposerCardMetrics.minHeight, alignment: .bottom)
        // Its own height whatever it is offered: a min-height frame offered less takes the
        // offer, and the grown draft ran outside the rounded card (user report 2026-11-12).
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ComposerCardChrome(look: look, shape: shape))
        // One container element that holds its own identifier (#55113): on the bare content a
        // caller's identifier went to every element inside, and the field read the card's id.
        .accessibilityElement(children: .contain)
    }
}

/// The card's colors: the app's plain glass (the agent chat), or a terminal theme's background
/// and text over the same glass, so the card reads as part of the pane under it.
public struct ComposerCardLook: Equatable, Sendable {
    /// The controls' glyphs; nil: the primary label color.
    public var ink: Color?
    /// A fill of the theme's background over the glass (nil: none). It also keeps the card the
    /// same shade at every height: bare glass over a terminal grew lighter as the draft grew
    /// (Leo, 2026-11-21: "the composer brightening up when you have >3 lines").
    public var fill: Color?
    /// The glass's tint (nil: untinted).
    public var tint: Color?
    /// A hairline around the card (nil: none). On a theme fill it alone marks the card's edge.
    public var border: Color?

    public init(ink: Color? = nil, fill: Color? = nil, tint: Color? = nil, border: Color? = nil) {
        self.ink = ink
        self.fill = fill
        self.tint = tint
        self.border = border
    }

    /// The app's own glass, untinted: the agent chat.
    public static let app = ComposerCardLook()

    /// A terminal theme's colors: the agent chat jump circle's numbers (a 72 % fill of the
    /// background over glass tinted 35 % toward it) on the theme's colors.
    public static func theme(background: Color, ink: Color) -> ComposerCardLook {
        ComposerCardLook(ink: ink, fill: background.opacity(fillOpacity), tint: background.opacity(tintOpacity),
                         border: Color.primary.opacity(0.16))
    }

    public static let fillOpacity: Double = 0.72
    public static let tintOpacity: Double = 0.35
}

/// The card's numbers, shared by both composers.
public enum ComposerCardMetrics {
    public static let cornerRadius: CGFloat = 24
    /// One line: the 44 pt row and 2 pt above and below it.
    public static let minHeight: CGFloat = 48
    public static let rowInset: CGFloat = 8
    public static let rowVerticalInset: CGFloat = 2
    /// The circles the controls draw; their touch targets reach 4 pt past them (44 pt).
    public static let control: CGFloat = 36
    /// The attachment strip over the row, both composers': 56 pt tiles under a 12 pt top inset.
    /// The field gives this height up while the strip shows (``ComposerFieldHeight/maxLines(_:sharing:lineHeight:)``).
    public static let attachmentStripHeight: CGFloat = 68
    /// The card's inset from the screen's sides.
    public static let horizontalInset: CGFloat = 12
}

private struct ComposerCardChrome<S: InsettableShape>: ViewModifier {
    let look: ComposerCardLook
    let shape: S

    func body(content: Content) -> some View {
        content
            .background { if let fill = look.fill { shape.fill(fill) } }
            .glassEffect(look.tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
            .overlay { if let border = look.border { shape.strokeBorder(border, lineWidth: 0.5) } }
    }
}

extension View {
    /// A composer control's look: a 36 pt circle of `fill` (the pressed wash included, under
    /// ``CmuxMobilePressFillStyle/cmuxPressFillInLabel``) with a 44 pt touch target that reports
    /// only the circle's size, so the row lays out the 36 pt circles.
    public func composerControlCircle(_ fill: some ShapeStyle) -> some View {
        frame(width: ComposerCardMetrics.control, height: ComposerCardMetrics.control)
            .cmuxMobilePressBackground(fill, in: Circle())
            .padding(4)
            .contentShape(.circle)
            .padding(-4)
    }
}
#endif
