import AppKit
import CmuxNextDesignTokens

/// How a keyed dialog button draws the key that presses it (Lawrence 2026-11-16 on the quit dialog's "esc" and "↩"
/// chips: "still looks bad, come up with more variations, think about how linear would do it"). ``plate`` is the look
/// every dialog draws today; the others are the Keycap Playground's candidates (``CmuxKeycapPlaygroundWindow``) until
/// one is picked.
enum CmuxDialogKeycapStyle: String, CaseIterable, Sendable {
    /// Today's look: a plate the button's height less a 3 pt inset, its fill the title's ink at 14%.
    case plate
    /// Linear's shortcut hint: a small 16 pt plate, a faint fill, the glyph at 11 pt, centred at the trailing end.
    case linearKbd
    /// No plate: the glyph after the title in the key hint's quieter ink, as a menu draws its keys.
    case plainGlyph
    /// A very faint fill (6%) with no border, the glyph a little dimmer.
    case faintFill
    /// A hairline outline with no fill.
    case hairline
    /// No plate, a smaller glyph at lower contrast, closer to the title.
    case quietSmall
    /// Only the default button shows its key, as a plain glyph; the others show none.
    case defaultOnly
    /// The buttons show no key; one caption under them names the keys.
    case outside

    /// The playground's name for the style.
    var title: String {
        switch self {
        case .plate: "1. Plate (today)"
        case .linearKbd: "2. Linear kbd"
        case .plainGlyph: "3. Plain glyph"
        case .faintFill: "4. Faint fill"
        case .hairline: "5. Hairline"
        case .quietSmall: "6. Quiet, small"
        case .defaultOnly: "7. Default button only"
        case .outside: "8. Outside the buttons"
        }
    }

    /// What the style changes, one line.
    var note: String {
        switch self {
        case .plate: "A 20 pt plate 3 pt in from the top, bottom and end; ink at 14%; corner 8 − 3 = 5 pt."
        case .linearKbd: "A 16 pt plate, ink at 10%, 11 pt glyph, 5 pt in from the end; corner 8 − 5 = 3 pt."
        case .plainGlyph: "No plate: the glyph 6 pt after the title, in the key hint's ink."
        case .faintFill: "An 18 pt plate, ink at 6%, no border; the glyph at 80%."
        case .hairline: "An 18 pt plate with a 1 px outline (ink at 22%) and no fill."
        case .quietSmall: "No plate: a 10 pt glyph at 55%, 4 pt after the title."
        case .defaultOnly: "Only ↩ on the default button, as a plain glyph; Cancel shows no key."
        case .outside: "No key in the buttons; a caption under them: “esc to cancel · ↩ to quit”."
        }
    }

    /// Whether a button in `role` draws its key inside itself.
    func showsKey(for role: CmuxDialogButton.Role) -> Bool {
        switch self {
        case .outside: false
        case .defaultOnly: role == .default
        default: true
        }
    }

    /// Whether the key sits on a plate (fill or outline); otherwise it is the bare glyph.
    var hasPlate: Bool {
        switch self {
        case .plate, .linearKbd, .faintFill, .hairline: true
        case .plainGlyph, .quietSmall, .defaultOnly, .outside: false
        }
    }

    /// The plate's fill: the title's ink at this alpha.
    var fillAlpha: CGFloat {
        switch self {
        case .plate: 0.14
        case .linearKbd: 0.10
        case .faintFill: 0.06
        default: 0
        }
    }

    /// The plate's outline: the title's ink at this alpha, 1 px; 0 draws none.
    var borderAlpha: CGFloat { self == .hairline ? 0.22 : 0 }

    /// The glyph's ink: the key hint's ink at this share of its alpha.
    var glyphAlpha: CGFloat {
        switch self {
        case .faintFill: 0.8
        case .quietSmall: 0.55
        default: 1
        }
    }

    /// The glyph's point size, before the person's text size.
    var glyphSize: CGFloat {
        switch self {
        case .linearKbd: 11
        case .quietSmall: 10
        default: TypeScale.caption
        }
    }

    /// The glyph's weight: a plate's glyph is emphasized; a bare glyph is regular, as a menu's.
    var glyphWeight: NSFont.Weight { hasPlate ? TypeScale.emphasis : .regular }

    /// The plate's height; nil fills the button less ``trailing`` above and below (``plate``).
    var plateHeight: CGFloat? {
        switch self {
        case .linearKbd: 16 * Typography.userScale
        case .faintFill, .hairline: 18 * Typography.userScale
        default: nil
        }
    }

    /// From the key's end to the button's trailing edge.
    var trailing: CGFloat {
        switch self {
        case .plate: CmuxDialogMetrics.keycapInset
        case .linearKbd: 5 * Typography.userScale
        case .faintFill, .hairline: 4 * Typography.userScale
        default: CmuxDialogMetrics.keycapLeading
        }
    }

    /// From the title's end to the key.
    var gap: CGFloat {
        switch self {
        case .plate: CmuxDialogMetrics.keycapGap
        case .plainGlyph, .defaultOnly: 6 * Typography.userScale
        case .quietSmall: 4 * Typography.userScale
        default: 6 * Typography.userScale
        }
    }

    /// The plate's room each side of the glyph.
    var platePadding: CGFloat { self == .linearKbd ? 4 * Typography.userScale : CmuxDialogMetrics.keycapPadding }

    /// The plate's corner for a plate `size` big: concentric with the button (its corner less the plate's inset from
    /// the end), at least ``CmuxDialogMetrics/keycapCornerFloor``, at most half the plate's height.
    func keycapCornerRadius(fitting size: CGSize) -> CGFloat {
        guard self != .plate else { return CmuxDialogMetrics.keycapCornerRadius(fitting: size) }
        let concentric = ConcentricContainer(outerRadius: CmuxDialogMetrics.keycapButtonCornerRadius, padding: trailing)
        return min(max(concentric.childRadius(fitting: size), CmuxDialogMetrics.keycapCornerFloor), min(size.width, size.height) / 2)
    }
}
