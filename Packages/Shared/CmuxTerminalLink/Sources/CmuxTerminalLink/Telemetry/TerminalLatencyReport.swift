/// One terminal's latency and catch-up numbers (c1-terminal-rpc.md section 8).
public struct TerminalLatencyReport: Hashable, Sendable {
    /// Input to first output past it, over the last samples.
    public var echoP50: Duration?
    public var echoP95: Duration?
    public var echoLast: Duration?
    public var echoSamples: Int
    /// Half the link RTT plus the newest frame's wait in the phone's queue.
    public var frameAge: Duration?
    public var linkRTT: Duration?
    /// READY frames applied (attach, grid change, resync).
    public var keyframes: Int
    /// Phone delivery-queue overflows (each cost one snapshot request).
    public var phoneOverflows: Int
    /// Link gaps and session losses that made the source reattach.
    public var reattaches: Int
    public var predictionsShown: Int
    public var predictionsConfirmed: Int
    public var predictionRollbacks: Int

    public init(echoP50: Duration? = nil, echoP95: Duration? = nil, echoLast: Duration? = nil, echoSamples: Int = 0,
                frameAge: Duration? = nil, linkRTT: Duration? = nil, keyframes: Int = 0, phoneOverflows: Int = 0,
                reattaches: Int = 0, predictionsShown: Int = 0, predictionsConfirmed: Int = 0, predictionRollbacks: Int = 0) {
        self.echoP50 = echoP50
        self.echoP95 = echoP95
        self.echoLast = echoLast
        self.echoSamples = echoSamples
        self.frameAge = frameAge
        self.linkRTT = linkRTT
        self.keyframes = keyframes
        self.phoneOverflows = phoneOverflows
        self.reattaches = reattaches
        self.predictionsShown = predictionsShown
        self.predictionsConfirmed = predictionsConfirmed
        self.predictionRollbacks = predictionRollbacks
    }
}
