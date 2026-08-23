#if os(iOS)
/// One screen of the first-run welcome tour.
///
/// The tour is a short, skippable pipeline: experience the product, opt in to
/// notifications where they were just demonstrated, sign in, and link a Mac.
/// Which stages actually present is decided by ``WelcomeStagePlan``; this enum
/// only names them in canonical order.
enum WelcomeStage: String, CaseIterable, Equatable {
    /// The interactive terminal demo that teaches the core loop by doing it.
    case hello

    /// The contextual notification opt-in, shown right after the demo where an
    /// agent asked for input.
    case notifications

    /// Embedded account sign-in, deferred until it gates the next step.
    case signIn

    /// Mac linking: live discovery plus the connection-method choices.
    case connect
}
#endif
