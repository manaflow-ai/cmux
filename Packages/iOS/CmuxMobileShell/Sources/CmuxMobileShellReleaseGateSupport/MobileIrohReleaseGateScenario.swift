#if DEBUG
/// Long-running relay credential behavior selected by the isolated release gate.
public enum MobileIrohReleaseGateScenario: String, Equatable, Sendable {
    /// Existing short app-RPC coverage.
    case standard
    /// Keep live application lanes open while the relay credential refreshes.
    case relayRollover = "relay_rollover"
    /// Hold the initial credential and require the relay to close at expiry.
    case relayExpiry = "relay_expiry"
}
#endif
