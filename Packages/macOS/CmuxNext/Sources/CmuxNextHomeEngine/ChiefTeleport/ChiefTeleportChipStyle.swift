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

    /// The playground's name for it (DEV-only English).
    public var title: String {
        switch self {
        case .plain: "Plain (shipped)"
        case .capsule: "Filled capsule"
        case .outline: "Outlined capsule"
        case .dot: "Status dot"
        case .iconOnly: "Glyph only"
        case .awayBadge: "Badge when away"
        }
    }

    var showsGlyph: Bool { self != .dot }
    var showsText: Bool { self != .iconOnly }
    var showsChevron: Bool { self != .iconOnly && self != .dot }
}
