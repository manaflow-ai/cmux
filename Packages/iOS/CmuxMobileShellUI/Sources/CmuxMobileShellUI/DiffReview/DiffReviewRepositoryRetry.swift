import CmuxMobileRPC

@MainActor
struct DiffReviewRepositoryRetry {
    let reloadStatus: () async -> Bool

    func run<Response>(_ operation: () async throws -> Response) async throws -> Response {
        do {
            return try await operation()
        } catch {
            guard Self.isStaleRepository(error), await reloadStatus() else {
                throw error
            }
            return try await operation()
        }
    }

    private static func isStaleRepository(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError,
              case .rpcError(let code, _) = connectionError else { return false }
        return code == "stale_repository"
    }
}
