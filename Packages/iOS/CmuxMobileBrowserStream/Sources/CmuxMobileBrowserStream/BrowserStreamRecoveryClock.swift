public import Foundation

/// Injectable monotonic clock for the stream liveness watchdog.
public protocol BrowserStreamRecoveryClock: Sendable {
    /// Monotonic seconds; only differences are meaningful.
    var now: TimeInterval { get }
    /// Cancellable bounded sleep.
    func sleep(for interval: TimeInterval) async throws
}

/// Production clock backed by `ContinuousClock`.
public struct BrowserStreamContinuousRecoveryClock: BrowserStreamRecoveryClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    /// Creates a clock anchored at construction time.
    public init() {
        origin = clock.now
    }

    public var now: TimeInterval {
        let components = origin.duration(to: clock.now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        try await clock.sleep(for: .seconds(interval))
    }
}
