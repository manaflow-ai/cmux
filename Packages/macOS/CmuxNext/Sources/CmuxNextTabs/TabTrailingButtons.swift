public import CoreGraphics
public import CmuxNextDesign

/// The look of a pane tab bar's trailing controls, the + (new tab), the ⌄ (pane-type chooser) and the ⋮ (pane menu)
/// (`TabTunables.trailingButtons`; the tab bar playground's Trailing Buttons page shows each live).
///
/// Lawrence 2026-11-07, a shot of `+ ⌄ ⋮` with a square grey block behind the ⌄: "i still dont like these UIs".
/// The + drew a bare stroke, the ⌄ an SF Symbol on a narrow rounded plate and the ⋮ a pack glyph on a square plate.
public nonisolated enum TabTrailingButtons: String, Sendable, CaseIterable, TunableChoice {
    /// Before 2026-11-07: rounded plates behind the ⌄ and ⋮, none behind the +.
    case plates
    /// No fill behind any of them: one stroke weight, ink brightens on hover and lights while pressed (the default).
    case glyphs
    /// One circle behind whichever control is hovered, the same diameter for all three.
    case circles
    /// `glyphs` without the ⌄: the + and the ⋮ only (the ⋮ menu and the +'s hold and right-click keep the pane types).
    case merged
    /// cmux classic's split button (Lucas 2026-11-11, a shot of classic's `+ ⌄`): the + and a narrower ⌄ side by
    /// side as one control with a button's corner (Lucas 2026-11-12); no fill at rest; under the pointer both
    /// segments take a soft fill and the hovered one the hover fill (the default).
    case split

    public var tunableTitle: String {
        switch self {
        case .plates: "Plates (before)"
        case .glyphs: "Glyphs only"
        case .circles: "Circles"
        case .merged: "Plus and More only"
        case .split: "Split button (classic)"
        }
    }

    /// The hover style the three controls share.
    public var hoverStyle: ChromeHoverStyle {
        switch self {
        case .plates, .split: .plate
        case .glyphs, .merged: .glyph
        case .circles: .circle
        }
    }

    /// Whether the pane-type ⌄ shows beside the + (where the pane asks for it).
    public var showsTypeChooser: Bool { self != .merged }

    /// The ⌄ segment's width beside a + of `plusWidth` in the split look: classic's 70% of the button, never under 14.
    public static func splitChevronWidth(plusWidth: CGFloat) -> CGFloat { max(14, (plusWidth * 0.7).rounded(.down)) }
}
