import Foundation

/// Injectable wall clock and cancellable suspension used by bounded retries.
struct PhonePushClock: Sendable {
    private let nowValue: @Sendable () -> Date
    private let sleepValue: @Sendable (Duration) async throws -> Void

    init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        nowValue = now
        sleepValue = sleep
    }

    var nowEpochSeconds: Int {
        Int(nowValue().timeIntervalSince1970.rounded(.down))
    }

    func sleep(for duration: Duration) async throws {
        try await sleepValue(duration)
    }

    static let live = Self(
        now: { Date() },
        sleep: { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    )
}
