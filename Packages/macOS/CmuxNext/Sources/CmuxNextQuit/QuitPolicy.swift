public import CmuxNextDaemonService
public import CmuxNextSettings

/// The App's side of the quit rules (`QuitRules`, CmuxNextDaemonService):
/// `app.quitBehavior` as the remembered choice.
public struct QuitPolicy {
    public init() {}
    /// `QuitRules.decide` with the setting's remembered choice (the setting's values are the choices' own).
    public static func decide(_ origin: QuitOrigin, behavior: QuitBehavior) -> QuitSessionsChoice {
        QuitRules.decide(origin, remembered: QuitSessionsChoice(rawValue: behavior.rawValue))
    }
}
