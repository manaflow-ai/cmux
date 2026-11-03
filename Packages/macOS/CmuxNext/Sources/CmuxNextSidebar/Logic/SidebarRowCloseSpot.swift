public import CmuxNextDesign

/// Where a hovered workspace row's close (✕) sits among its other trailing controls: the menu (⋮), the tab
/// chevron and the status mark on the trailing column (`sidebar.rowCloseSpot`). Leo 2026-10-27: "I now feel
/// like the X is a bit off center ... the rightmost three things, they make sense, but this one, not so much
/// ... Here, I'll just highlight what Chrome has." Chrome's tab group header shows only ⋮ and its chevron, at
/// its end. The gallery (`SidebarRowCloseSpotGalleryTests`) draws every choice. Under every choice the status mark
/// hides while the close or the menu shows (Leo 2026-10-28: "just don't show the spinner").
public nonisolated enum SidebarRowCloseSpot: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// ⋮ ⌄ ✕: the close takes the row's end on hover, where the status mark was; the mark gives way while the
    /// row is hovered. Nothing sits between the menu and the chevron.
    case end
    /// ⋮ ✕ ⌄ ●, the gap to the status column made as even as the gaps between the controls.
    case even
    /// ⋮ ✕ ⌄ ●, the ✕ drawn a size smaller, so it reads as light as the ⋮ and the chevron.
    case lighter
    /// `end` with the smaller ✕.
    case endLighter
    /// ⋮ ✕ ⌄ ●: the close between the menu and the chevron (before 2026-10-27).
    case middle

    public var tunableTitle: String {
        switch self {
        case .end: "At the end (⋮ ⌄ ✕)"
        case .even: "Even gaps"
        case .lighter: "Smaller ✕"
        case .endLighter: "At the end, smaller ✕"
        case .middle: "Between ⋮ and the chevron"
        }
    }

    /// The close takes the row's end on hover.
    var atEnd: Bool { self == .end || self == .endLighter }
    /// The close draws a size smaller than the other controls' glyphs.
    var smallerGlyph: Bool { self == .lighter || self == .endLighter }
}
