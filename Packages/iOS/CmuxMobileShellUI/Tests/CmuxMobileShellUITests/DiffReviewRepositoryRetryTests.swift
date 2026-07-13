import CmuxDiffModel
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

        let value: String = try await retry.run { _ in
            attempts += 1
            if attempts == 1 {
                throw WorkspaceDiffError.staleRepository
            }
            return "fresh"
        }

        #expect(value == "fresh")
        #expect(reloads == 1)
        #expect(attempts == 2)
    }

    @Test func retryIdentifiesTheAttemptThatMustUseReloadedFileMetadata() async throws {
        let retry = DiffReviewRepositoryRetry { true }

        let value: String = try await retry.run { attempt in
            switch attempt {
            case .initial:
                throw WorkspaceDiffError.staleRepository
            case .reloaded:
                return "fresh metadata"
            }
        }

        #expect(value == "fresh metadata")
    }
}
