/// Lifecycle phase for a nested-provider connection.
public enum NestedProviderConnectionState: String, CaseIterable, Codable, Sendable {
    /// No provider is attached.
    case disconnected

    /// Transport connection is being established.
    case connecting

    /// Protocol and capability negotiation is in progress.
    case negotiating

    /// A coherent snapshot and event boundary are being established.
    case syncing

    /// Current topology is live and mutations may be considered separately.
    case live

    /// Last topology is retained but incremental state is no longer trusted.
    case stale

    /// Provider protocol is outside the tested compatibility range.
    case incompatible

    /// Endpoint or attachment failed a trust or authorization check.
    case rejected

    /// Connection ended with a recoverable provider or transport failure.
    case failed
}
