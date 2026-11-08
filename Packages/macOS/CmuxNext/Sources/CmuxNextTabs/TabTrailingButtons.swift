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

    public var tunableTitle: String {
        switch self {
        case .plates: "Plates (before)"
        case .glyphs: "Glyphs only"
        case .circles: "Circles"
        case .merged: "Plus and More only"
        }
    }

    /// The hover style the three controls share.
    public var hoverStyle: ChromeHoverStyle {
        switch self {
        case .plates: .plate
        case .glyphs, .merged: .glyph
        case .circles: .circle
        }
    }

    /// Whether the pane-type ⌄ shows beside the + (where the pane asks for it).
    public var showsTypeChooser: Bool { self != .merged }
}
