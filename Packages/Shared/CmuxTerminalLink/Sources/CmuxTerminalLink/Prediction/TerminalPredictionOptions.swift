/// Local echo prediction (c1-terminal-rpc.md section 8). Off by default.
public struct TerminalPredictionOptions: Hashable, Sendable {
    public var enabled: Bool
    /// Below this round trip the real echo already lands within two frames.
    public var minimumRTT: Duration
    /// Verbatim echoes in a row before predictions are shown.
    public var confirmationsToPredict: Int
    /// An unconfirmed shown prediction older than `max(minimumExpiry, 3 x RTT)` rolls back.
    public var minimumExpiry: Duration

    public init(enabled: Bool = false, minimumRTT: Duration = .milliseconds(30), confirmationsToPredict: Int = 2,
                minimumExpiry: Duration = .milliseconds(250)) {
        self.enabled = enabled
        self.minimumRTT = minimumRTT
        self.confirmationsToPredict = max(0, confirmationsToPredict)
        self.minimumExpiry = minimumExpiry
    }
}
