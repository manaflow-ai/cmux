@MainActor
final class DiffReviewRepositoryRetryBudget {
    private var consumedRequest: DiffReviewRepositoryRetryRequest?

    func claimAutomaticRetry(for request: DiffReviewRepositoryRetryRequest) -> Bool {
        guard consumedRequest != request else { return false }
        consumedRequest = request
        return true
    }

    func recordSuccess(for request: DiffReviewRepositoryRetryRequest) {
        if consumedRequest == request {
            consumedRequest = nil
        }
    }
}
