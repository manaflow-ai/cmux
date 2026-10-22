/// Bounded numeric context linking an Axiom window to a nonfatal Sentry event.
public struct MobileFeedScrollAnomaly: Sendable {
    /// Random identifier for this measurement window, unrelated to user content.
    public let windowID: String
    /// Largest callback gap in milliseconds, capped at sixty seconds.
    public let maxGapMilliseconds: Int
    /// Number of observed callback intervals, not rendered frames.
    public let callbackCount: Int
    /// Largest retained Feed item count in the window.
    public let itemCount: Int

    /// Creates an anomaly from a completed measurement window.
    public init(windowID: String, maxGapMilliseconds: Int, callbackCount: Int, itemCount: Int) {
        self.windowID = windowID
        self.maxGapMilliseconds = maxGapMilliseconds
        self.callbackCount = callbackCount
        self.itemCount = itemCount
    }
}
