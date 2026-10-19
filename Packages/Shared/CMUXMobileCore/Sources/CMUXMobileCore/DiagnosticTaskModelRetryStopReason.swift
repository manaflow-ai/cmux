/// Why task model discovery stopped retrying.
///
/// These values are only emitted when another request would repeat a known
/// permanent failure.
public enum DiagnosticTaskModelRetryStopReason: Int, Sendable, Codable, CaseIterable {
    /// The host does not implement the model discovery capability.
    case unsupported = 1
    /// The host has disabled the model discovery capability.
    case disabled = 2
    /// The current session needs authorization before discovery can work.
    case authorizationRequired = 3
    /// The host and mobile client belong to different accounts.
    case accountMismatch = 4
    /// The request parameters are permanently invalid.
    case invalidRequest = 5
    /// The selected provider is not installed on the host.
    case providerUnavailable = 6
    /// The owner cancelled discovery.
    case cancelled = 7
}
