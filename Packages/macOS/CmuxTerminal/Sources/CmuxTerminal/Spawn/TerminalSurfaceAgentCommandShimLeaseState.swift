internal import CmuxTerminalCore
internal import Foundation

actor TerminalSurfaceAgentCommandShimLeaseState {
    private var shims: TerminalSurfaceAgentCommandShimSet?
    private var removalAttempt: (id: UUID, task: Task<Void, any Error>)?
    private let removalAttemptLimit: Int
    private let remove: @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void
    private let reportRemovalFailure:
        @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void

    var hasOwnedShims: Bool { shims != nil }

    init(
        shims: TerminalSurfaceAgentCommandShimSet,
        removalAttemptLimit: Int,
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportRemovalFailure:
            @escaping @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    ) {
        precondition(removalAttemptLimit > 0)
        self.shims = shims
        self.removalAttemptLimit = removalAttemptLimit
        self.remove = remove
        self.reportRemovalFailure = reportRemovalFailure
    }

    func release() async -> Bool {
        guard let shims else { return true }
        let attempt: (id: UUID, task: Task<Void, any Error>)
        if let removalAttempt {
            attempt = removalAttempt
        } else {
            let id = UUID()
            let remove = remove
            let removalAttemptLimit = removalAttemptLimit
            let task = Task.detached(priority: .utility) {
                var lastError: (any Error)?
                for _ in 0..<removalAttemptLimit {
                    do {
                        try await remove(shims)
                        return
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? CancellationError()
            }
            attempt = (id: id, task: task)
            removalAttempt = attempt
        }

        do {
            try await attempt.task.value
            guard removalAttempt?.id == attempt.id else { return self.shims == nil }
            self.shims = nil
            removalAttempt = nil
            return true
        } catch {
            guard removalAttempt?.id == attempt.id else { return self.shims == nil }
            removalAttempt = nil
            reportRemovalFailure(shims, String(reflecting: error))
            return false
        }
    }
}
