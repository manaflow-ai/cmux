/// How a card that hangs from its target (a tab's, a group chip's, a Home link chip's: the `.below` and
/// `.above` placements) moves when the pointer goes to the next target while it shows. A tab's card reads
/// it from `TabTunables.hoverCardRetarget` (Debug Settings); the tab bar playground's Hover Card page shows
/// the three side by side.
///
/// Leo 2026-11-18, a recording of the pointer crossing two agent tabs: "the hover preview bounces for some
/// reason". Frame by frame the card slid from the last tab to the next on the `.panel` spring and eased into
/// place over about 200 ms while its content crossfaded and it resized (`glide`, Lawrence 2026-11-15,
/// msg 34360). The card now switches in place: it is under the next tab with that tab's content in the
/// same frame, as Chrome's tab preview is.
public nonisolated enum HoverCardRetarget: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// The card is at the next target with its content in the same frame: no slide, no crossfade, no resize
    /// on a spring.
    case jump
    /// The card is at the next target in the same frame; only its content crossfades.
    case crossfade
    /// The card glides the whole way to the next target on one spring while the content crossfades at its
    /// own size and the card resizes (`HoverCardPanel+Glide.swift`).
    case glide

    public var tunableTitle: String {
        switch self {
        case .jump: "Switch in place"
        case .crossfade: "Switch in place, crossfade content"
        case .glide: "Glide to the next tab"
        }
    }
}
