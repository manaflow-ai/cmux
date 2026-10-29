/// Fail-closed reasons that prevent an explicit private-address dial.
public enum CmxIrohPrivateFallbackValidationError: Error, Equatable, Sendable {
    /// No generation-aware network observer can validate the fallback.
    case unavailable

    /// The authorization does not describe the session's exact private hints.
    case authorizationMismatch

    /// The local network path changed after the hints were admitted.
    case generationChanged

    /// An admitted provider-qualified profile is no longer active.
    case profileUnavailable

    /// An admitted hint expired or no longer satisfies current wire policy.
    case hintExpiredOrInvalid
}
