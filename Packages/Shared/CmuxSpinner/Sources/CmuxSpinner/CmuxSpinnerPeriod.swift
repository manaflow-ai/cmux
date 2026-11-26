public import Foundation

/// How long one turn of a cmux spinner takes: the period every cmux spinner turns at, on the Mac,
/// the phone and the web pages alike (`spinner` in schemas/motion-scale/motion-scale.json, which
/// scripts/cmux-next/gen-motion-scale.py writes into the default below; CmuxSpinnerTests checks it).
public nonisolated struct CmuxSpinnerPeriod: Sendable, Hashable {
    /// Seconds per turn.
    public let seconds: TimeInterval

    /// - Parameter seconds: Seconds per turn; the shared period unless a test passes its own.
    public init(seconds: TimeInterval = 2) { self.seconds = seconds } // spinner-period: gen-motion-scale.py

    /// The media time a turn must begin at for its phase at `mediaTime` to be `unixTime` mod the period, so every
    /// spinner sits at the same angle at the same moment (CmuxSpinnerLayer passes its process's Unix-time offset).
    public func turnBegan(mediaTime: TimeInterval, unixTime: TimeInterval) -> TimeInterval {
        guard seconds > 0 else { return mediaTime }
        let into = unixTime.truncatingRemainder(dividingBy: seconds)
        return mediaTime - (into < 0 ? into + seconds : into)
    }
}
