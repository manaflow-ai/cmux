/// Monotonic milliseconds for a sizing host's attach and activity times.
///
/// ``TerminalSizingEngine`` never reads a clock; the host passes the time of
/// each event. Inject a fixed clock in tests to control the activity hold.
public struct TerminalSizingClock: Sendable {
    private let read: @Sendable () -> UInt64

    /// - Parameter milliseconds: returns a non-decreasing time in milliseconds.
    public init(milliseconds: @escaping @Sendable () -> UInt64) {
        read = milliseconds
    }

    /// The current time in milliseconds.
    public var milliseconds: UInt64 { read() }

    /// Milliseconds of `ContinuousClock` since this clock was made.
    public static func continuous() -> TerminalSizingClock {
        let origin = ContinuousClock.now
        return TerminalSizingClock {
            let elapsed = origin.duration(to: ContinuousClock.now).components
            return UInt64(max(0, elapsed.seconds)) * 1000 + UInt64(max(0, elapsed.attoseconds)) / 1_000_000_000_000_000
        }
    }
}
