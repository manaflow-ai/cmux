/// Failures from a subrouter account switch.
public enum SubrouterSwitchError: Error, Sendable, Equatable {
    /// The subrouter integration is disabled in settings.
    case integrationDisabled
    /// The provider has no CLI switch verb (e.g. Gemini).
    case switchUnsupported(provider: SubrouterProvider)
    /// Neither the configured command path nor `sr`/`subrouter` on `PATH`
    /// (or the standard install locations) could be launched.
    case commandNotFound
    /// The `sr` invocation ran but failed; carries trimmed stderr/stdout.
    case commandFailed(description: String)
    /// The `sr` invocation exceeded its deadline and was terminated.
    case commandTimedOut
    /// A switch for the same provider is already in flight.
    case switchAlreadyInFlight
    /// The configured daemon is a remote subrouter server, which assigns
    /// accounts per session on the server side; `sr switch` refuses to edit
    /// local state in that mode.
    case remoteServerManagesSelection(serverName: String)
}
