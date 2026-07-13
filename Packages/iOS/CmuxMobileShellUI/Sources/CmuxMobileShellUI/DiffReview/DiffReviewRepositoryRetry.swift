import CmuxDiffModel

@MainActor
struct DiffReviewRepositoryRetry {
    enum Attempt {
        case initial
        case reloaded
    }

    let reloadStatus: () async -> Bool

    func run<Response>(_ operation: (Attempt) async throws -> Response) async throws -> Response {
        do {
            return try await operation(.initial)
        } catch {
            guard Self.isStaleRepository(error), await reloadStatus() else {
                throw error
            }
            try Task.checkCancellation()
            return try await operation(.reloaded)
        }
    }

    private static func isStaleRepository(_ error: any Error) -> Bool {
        guard let diffError = error as? WorkspaceDiffError else { return false }
        return diffError == .staleRepository
    }
}
