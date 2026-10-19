/// Localized validation messages for surface resume commands.
///
/// The app supplies these values so `String(localized:)` resolves against the
/// app bundle instead of the package bundle.
public struct ControlSurfaceResumeStrings: Sendable, Equatable {
    /// The message returned when `agent_session_ended` is not a JSON boolean.
    public let agentSessionEndedMustBeBoolean: String
    /// The message returned when `launch_command` is present but malformed.
    public let launchCommandMustBeValid: String
    /// The message returned when a restore claim is incomplete or malformed.
    public let restoreClaimMustBeValid: String

    /// Creates the localized surface-resume message bundle.
    ///
    /// - Parameters:
    ///   - agentSessionEndedMustBeBoolean: The malformed
    ///     `agent_session_ended` message.
    ///   - launchCommandMustBeValid: The malformed `launch_command` message.
    ///   - restoreClaimMustBeValid: The malformed restore-claim message.
    public init(
        agentSessionEndedMustBeBoolean: String,
        launchCommandMustBeValid: String,
        restoreClaimMustBeValid: String = ""
    ) {
        self.agentSessionEndedMustBeBoolean = agentSessionEndedMustBeBoolean
        self.launchCommandMustBeValid = launchCommandMustBeValid
        self.restoreClaimMustBeValid = restoreClaimMustBeValid
    }
}
