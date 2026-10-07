/// Time from a fault (transport drop, or a roam to a new path) to the first
/// echo answered afterwards. The probe is sent right after the fault, so
/// reliable retention and replay are part of what is measured.
public struct RecoveryResult: Codable, Sendable {
    public var fault: String
    public var recovered: Distribution
    public var samples: [Double]
    public var failures: Int
    /// Whether the `LinkSession` went through `reconnecting` (false means the
    /// carrier kept its transport and only moved the path).
    public var sessionReconnected: [Bool]
    public var pathAfter: [String]
}
