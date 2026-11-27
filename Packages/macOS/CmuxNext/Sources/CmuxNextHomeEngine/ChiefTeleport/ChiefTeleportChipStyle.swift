/// How the Chief's location chip draws (Debug > Chief Teleport Playground compares them; the app
/// ships ``plain``, the simplest).
public nonisolated enum ChiefTeleportChipStyle: Int, CaseIterable, Sendable {
    /// A glyph, the place and a chevron in secondary text, no fill (shipped).
    case plain
    /// The same on a soft filled capsule.
    case capsule
    /// The same in a hairline capsule.
    case outline
    /// A status dot and the place, no glyph.
    case dot
    /// Only the glyph; the place is its tooltip and VoiceOver label.
    case iconOnly
    /// Plain on This Mac; a filled capsule while the Chief is away or a move runs.
    case awayBadge
    /// Drawn like the profile panel's pop-up buttons (the theme's selection fill, control height, body text,
    /// an up-down chevron at the trailing edge): the Runs On row beside the Harness and Computer Use pickers.
    case field

    /// The playground's name for it (DEV-only English).
    public var title: String {
        switch self {
        case .plain: "Plain (shipped)"
        case .capsule: "Filled capsule"
        case .outline: "Outlined capsule"
        case .dot: "Status dot"
        case .iconOnly: "Glyph only"
        case .awayBadge: "Badge when away"
        case .field: "Pop-up field (profile panel)"
        }
    }

    var showsGlyph: Bool { self != .dot }
    var showsText: Bool { self != .iconOnly }
    var showsChevron: Bool { self != .iconOnly && self != .dot }
}
