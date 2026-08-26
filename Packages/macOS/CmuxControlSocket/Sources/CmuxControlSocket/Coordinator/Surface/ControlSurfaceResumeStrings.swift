/// Localized validation messages for surface resume commands.
///
/// The app supplies these values so `String(localized:)` resolves against the
/// app bundle instead of the package bundle.
public struct ControlSurfaceResumeStrings: Sendable, Equatable {
    /// The message returned when `agent_session_ended` is not a JSON boolean.
    public let agentSessionEndedMustBeBoolean: String
    /// The message returned when the internal binding-revision guard is invalid.
    public let invalidExpectedUpdatedAt: String
    /// The message returned when `launch_command` is present but malformed.
    public let launchCommandMustBeValid: String
    /// The message returned when the private agent occupant guard is malformed.
    public let agentMutationGuardMustBeValid: String

    /// Creates the localized surface-resume message bundle.
    ///
    /// - Parameters:
    ///   - agentSessionEndedMustBeBoolean: The malformed
    ///     `agent_session_ended` message.
    ///   - invalidExpectedUpdatedAt: The malformed internal binding-revision
    ///     guard message.
    ///   - launchCommandMustBeValid: The malformed `launch_command` message.
    ///   - agentMutationGuardMustBeValid: The malformed private occupant-guard message.
    public init(
        agentSessionEndedMustBeBoolean: String,
        invalidExpectedUpdatedAt: String,
        launchCommandMustBeValid: String,
        agentMutationGuardMustBeValid: String
    ) {
        self.agentSessionEndedMustBeBoolean = agentSessionEndedMustBeBoolean
        self.invalidExpectedUpdatedAt = invalidExpectedUpdatedAt
        self.launchCommandMustBeValid = launchCommandMustBeValid
        self.agentMutationGuardMustBeValid = agentMutationGuardMustBeValid
    }
}
