import Foundation
@testable import CmuxIrohTransport

/// Completes retry delays immediately so cold-start recovery tests stay deterministic.
struct ImmediateHostActivationClock: CmxIrohRelayClock {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        date
    }

    func sleep(until _: Date) async throws {}
}
