/// One screen of Meet Chief (``ChiefOnboarding``), simplest first: who Chief is and what it does, then what it
/// may do on this Mac, then how cmux looks. Cloud, the app store and the rest wait until the person asks
/// (progressive complexity, David Beyer 2026-11-20).
public enum ChiefOnboardingStep: String, CaseIterable, Hashable, Sendable {
    /// Who Chief is, and what it does for the person: agents, memory, follow-ups.
    case meet
    /// What Chief may do on this Mac (`chief.permissionMode`), the choice of it, and where to change it later.
    case access
    /// How cmux looks: its density (`appearance.density`) and text size (`appearance.metrics.chromeFontSize`), live.
    case look
}
