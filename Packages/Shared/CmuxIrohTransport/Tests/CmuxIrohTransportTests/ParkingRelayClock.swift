import Foundation
@testable import CmuxIrohTransport

/// A retry clock whose sleep parks (cancellation-aware) for an hour, so the
/// retired-dial dead-man bound can never fire inside a test. Any progress a
/// test observes therefore proves dials settled via cancellation, not the bound.
struct ParkingRelayClock: CmxIrohRelayClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(until _: Date) async throws { try await Task.sleep(for: .seconds(3_600)) }
}
