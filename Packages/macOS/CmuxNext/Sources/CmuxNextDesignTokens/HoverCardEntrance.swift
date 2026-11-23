/// How a hover card's first show plays (a retarget always slides and morphs the one card). A tab's
/// card reads it from `TabTunables.hoverCardEntrance` (Debug Settings); the tab bar playground's
/// Hover Card page shows the three side by side.
public nonisolated enum HoverCardEntrance: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// Fades in where it rests.
    case fade
    /// Fades in while it moves the last few points away from its target (`HoverCardMotion`).
    case slide
    /// Grows out of its target: from the target's width at its touching edge to its full size,
    /// on the settle spring (it stops on its rest size), like a drop pulling away from a surface (Leo
    /// 2026-11-07: "do we want to make it, like, morph together with the tab? ... I wanted to have
    /// goo, right? ... that water surface tension thing").
    case morph

    public var tunableTitle: String {
        switch self {
        case .fade: "Fade"
        case .slide: "Fade and slide"
        case .morph: "Grow out of the tab"
        }
    }
}
