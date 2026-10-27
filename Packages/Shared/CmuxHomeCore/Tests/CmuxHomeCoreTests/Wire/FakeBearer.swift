@testable import CmuxHomeCore

/// A Stack token provider that counts the refreshes it was asked for.
final class FakeBearer: HomeBearerProviding {
    // A test fake: the lock guards the refresh count the test reads synchronously.
    private let state = Locked((issued: 0, refreshes: 0))

    var refreshes: Int { state.withLock { $0.refreshes } }

    func accessToken(forceRefresh: Bool) async throws -> String {
        state.withLock { state -> String in
            state.issued += 1
            if forceRefresh { state.refreshes += 1 }
            return "token-\(state.issued)"
        }
    }
}
