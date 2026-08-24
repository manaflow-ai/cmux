/// Failures from a subrouter account switch.
public enum SubrouterSwitchError: Error, Sendable, Equatable {
    /// The subrouter integration is disabled in settings.
    case integrationDisabled
    /// The provider has no CLI switch verb (e.g. Gemini).
    case switchUnsupported(provider: SubrouterProvider)
    /// Neither the configured command path nor `sr`/`subrouter` on `PATH`
    /// (or the standard install locations) could be launched.
    case commandNotFound
    /// The `sr` invocation ran but failed. Detailed subprocess output is
    /// logged internally by ``SubrouterCommandSwitcher`` and never crosses
    /// the public error boundary.
    case commandFailed
    /// The `sr` invocation exceeded its deadline and was terminated.
    case commandTimedOut
    /// A switch for the same provider is already in flight.
    case switchAlreadyInFlight
    /// The configured remote subrouter server predates the
    /// `/_subrouter/switch-account` endpoint (it answered 404/501), so it
    /// can only assign accounts per session; upgrading the server enables
    /// remote switching.
    case remoteServerManagesSelection(serverName: String)
}
