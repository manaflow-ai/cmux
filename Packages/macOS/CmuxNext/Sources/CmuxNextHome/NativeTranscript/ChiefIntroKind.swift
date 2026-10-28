/// Which first-open intro a Chief's empty conversation shows (`HomeFirstRunIntro`, ``ChiefIntroStore``).
public enum ChiefIntroKind: String, Hashable, Sendable {
    /// The person's only Chief: what Chief is and how to start (`HomeStrings.firstRunIntro`).
    case welcome
    /// A new Chief beside the person's other Chiefs: it asks what it should focus on.
    case askFocus
}
