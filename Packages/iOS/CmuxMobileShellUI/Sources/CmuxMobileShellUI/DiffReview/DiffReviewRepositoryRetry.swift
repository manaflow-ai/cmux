import CmuxDiffModel

@MainActor
struct DiffReviewRepositoryRetry {
    let request: DiffReviewRepositoryRetryRequest
    let budget: DiffReviewRepositoryRetryBudget
    let reloadStatus: () async -> Bool

    init(
        request: DiffReviewRepositoryRetryRequest = .unspecified,
        budget: DiffReviewRepositoryRetryBudget = DiffReviewRepositoryRetryBudget(),
        reloadStatus: @escaping () async -> Bool
    ) {
        self.request = request
        self.budget = budget
        self.reloadStatus = reloadStatus
    }

    func run<Response>(
        _ operation: (DiffReviewRepositoryRetryAttempt) async throws -> Response
    ) async throws -> Response {
        do {
            let response = try await operation(.initial)
            budget.recordSuccess(for: request)
            return response
        } catch {
            guard let diffError = error as? WorkspaceDiffError,
                  diffError == .staleRepository,
                  budget.claimAutomaticRetry(for: request),
                  await reloadStatus() else {
                throw error
            }
            try Task.checkCancellation()
            let response = try await operation(.reloaded)
            budget.recordSuccess(for: request)
            return response
        }
    }
}
