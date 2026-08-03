/// A constrained action the Realtime model may request from the iOS app.
public enum RealtimeVoiceToolCall: Equatable, Sendable {
    /// Return a fresh inventory of visible terminal targets across paired Macs.
    case listTerminals
    /// Deliver the exact latest user transcript to the selected opaque targets.
    case sendLatestUtterance(targetIDs: [String])
}
