/// Localized validation messages for surface resume commands.
///
/// The app supplies these values so `String(localized:)` resolves against the
/// app bundle instead of the package bundle.
public struct ControlSurfaceResumeStrings: Sendable, Equatable {
    /// The message returned when `agent_session_ended` is not a JSON boolean.
    public let agentSessionEndedMustBeBoolean: String

    /// Creates the localized surface-resume message bundle.
    ///
    /// - Parameter agentSessionEndedMustBeBoolean: The malformed
    ///   `agent_session_ended` message.
    public init(agentSessionEndedMustBeBoolean: String) {
        self.agentSessionEndedMustBeBoolean = agentSessionEndedMustBeBoolean
    }
}
