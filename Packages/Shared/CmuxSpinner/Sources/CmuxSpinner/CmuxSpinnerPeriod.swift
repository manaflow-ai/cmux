public import Foundation

/// How long one turn of a cmux spinner takes: the period every cmux spinner turns at, on the Mac,
/// the phone and the web pages alike (`spinner` in schemas/motion-scale/motion-scale.json, which
/// scripts/cmux-next/gen-motion-scale.py writes into the default below; CmuxSpinnerTests checks it).
public nonisolated struct CmuxSpinnerPeriod: Sendable, Hashable {
    /// Seconds per turn.
    public let seconds: TimeInterval

    /// - Parameter seconds: Seconds per turn; the shared period unless a test passes its own.
    public init(seconds: TimeInterval = 2) { self.seconds = seconds } // spinner-period: gen-motion-scale.py
}
