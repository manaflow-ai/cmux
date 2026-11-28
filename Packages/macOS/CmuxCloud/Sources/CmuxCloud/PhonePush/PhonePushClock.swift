import Foundation

/// Injectable wall clock and cancellable suspension used by bounded retries.
public struct PhonePushClock: Sendable {
    private let nowValue: @Sendable () -> Date
    private let sleepValue: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        nowValue = now
        sleepValue = sleep
    }

    public var nowEpochSeconds: Int {
        Int(nowValue().timeIntervalSince1970.rounded(.down))
    }

    public func sleep(for duration: Duration) async throws {
        try await sleepValue(duration)
    }

    public static let live = Self(
        now: { Date() },
        sleep: { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    )
}
