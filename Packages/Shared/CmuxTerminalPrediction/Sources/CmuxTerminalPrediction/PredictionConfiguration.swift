/// Monotonic time supplied by the host, so the engine holds no clock and tests
/// state exact instants instead of sleeping.
public typealias PredictionInstant = Duration

public struct PredictionConfiguration: Sendable, Equatable {
    /// Below this measured echo latency, predicting is not worth the risk: a
    /// local shell already paints faster than a person can notice.
    public var engageAboveEchoLatency: Duration
    /// A speculative glyph the remote never echoes is withdrawn after this.
    public var speculativeLifetime: Duration
    /// How long a confirmed glyph keeps drawing while waiting for the frame
    /// that contains the real character, if the host never reports one.
    public var confirmationHold: Duration
    /// Withdrawals of glyphs the user actually saw, within `mispredictionWindow`,
    /// that suspend prediction.
    public var mispredictionsBeforeSuspending: Int
    public var mispredictionWindow: Duration
    public var suspension: Duration
    /// Predicting further than this ahead of the remote stops being a latency
    /// hint and starts being a second, wrong terminal.
    public var maximumSpeculativeGlyphs: Int

    public init(
        engageAboveEchoLatency: Duration = .milliseconds(25),
        speculativeLifetime: Duration = .milliseconds(1500),
        confirmationHold: Duration = .milliseconds(120),
        mispredictionsBeforeSuspending: Int = 4,
        mispredictionWindow: Duration = .seconds(10),
        suspension: Duration = .seconds(30),
        maximumSpeculativeGlyphs: Int = 40
    ) {
        self.engageAboveEchoLatency = engageAboveEchoLatency
        self.speculativeLifetime = speculativeLifetime
        self.confirmationHold = confirmationHold
        self.mispredictionsBeforeSuspending = mispredictionsBeforeSuspending
        self.mispredictionWindow = mispredictionWindow
        self.suspension = suspension
        self.maximumSpeculativeGlyphs = maximumSpeculativeGlyphs
    }

    public static let `default` = PredictionConfiguration()
}
