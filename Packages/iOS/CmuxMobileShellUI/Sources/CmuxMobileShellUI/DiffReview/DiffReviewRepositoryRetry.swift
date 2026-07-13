import CmuxDiffModel

struct DiffReviewRepositoryRetryRequest: Equatable {
    let path: String
    let oldPath: String?
    let status: DiffFileStatus
    let manualAttempt: Int

    static let unspecified = Self(
        path: "",
        oldPath: nil,
        status: .modified,
        manualAttempt: 0
    )
}

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

@MainActor
struct DiffReviewRepositoryRetry {
    enum Attempt {
        case initial
        case reloaded
    }

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

    func run<Response>(_ operation: (Attempt) async throws -> Response) async throws -> Response {
        do {
            let response = try await operation(.initial)
            budget.recordSuccess(for: request)
            return response
        } catch {
            guard Self.isStaleRepository(error),
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

    private static func isStaleRepository(_ error: any Error) -> Bool {
        guard let diffError = error as? WorkspaceDiffError else { return false }
        return diffError == .staleRepository
    }
}
