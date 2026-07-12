import CmuxMobileRPC
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite struct DiffReviewRepositoryRetryTests {
    @Test func staleRepositoryReloadsStatusBeforeRetryingFile() async throws {
        var reloads = 0
        var attempts = 0
        let retry = DiffReviewRepositoryRetry {
            reloads += 1
            return true
        }

        let value: String = try await retry.run {
            attempts += 1
            if attempts == 1 {
                throw MobileShellConnectionError.rpcError("stale_repository", "stale")
            }
            return "fresh"
        }

        #expect(value == "fresh")
        #expect(reloads == 1)
        #expect(attempts == 2)
    }
}
