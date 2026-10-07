/// AIMD bitrate target from rd feedback (c2-browser-stream.md section 3):
/// loss above 2% or a recovery request multiplies by 0.7; a clean second
/// adds 10%. Times are the caller's monotonic clock.
public struct BrowserBitrateController: Hashable, Sendable {
    public private(set) var target: Int
    public let minimum: Int
    public let maximum: Int
    private var cleanSince: Duration?

    public init(start: Int = 3_000_000, minimum: Int = 300_000, maximum: Int = 12_000_000) {
        self.minimum = minimum
        self.maximum = maximum
        target = min(max(start, minimum), maximum)
    }

    /// `lossFraction` is the share of datagrams sent since the previous
    /// feedback that did not arrive.
    public mutating func feedback(lossFraction: Double, needRecovery: Bool, now: Duration) {
        if needRecovery || lossFraction > 0.02 {
            decrease()
            cleanSince = nil
            return
        }
        guard let since = cleanSince else {
            cleanSince = now
            return
        }
        if now - since >= .seconds(1) {
            target = min(maximum, target + target / 10)
            cleanSince = now
        }
    }

    /// A stream-mode send waited longer than two frame intervals.
    public mutating func sendStalled() {
        decrease()
        cleanSince = nil
    }

    private mutating func decrease() {
        target = max(minimum, target * 7 / 10)
    }
}
