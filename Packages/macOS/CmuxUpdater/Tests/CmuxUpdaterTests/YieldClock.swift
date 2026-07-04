@testable import CmuxUpdater

/// A clock whose sleeps return immediately after yielding, so polling loops advance without
/// real waiting in tests.
struct YieldClock: UpdateClock {
    func sleep(for duration: Duration) async throws {
        await Task.yield()
    }
}
