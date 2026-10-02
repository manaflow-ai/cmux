import CmuxSurfaceCatalogModel
import Foundation

/// A coalesced Cloud projection operation carries a generation token so a late
/// completion from an old transport cannot clear a newer retry in the provider.
@MainActor
struct CloudTerminalProjectionTask {
    let token: UUID
    let task: Task<SurfaceRemotePlacement, Error>
    let completion: CloudProjectionCompletion
}

/// Owns coalesced terminal projections independently of any one local waiter.
/// A cancelled waiter only loses its await; the registry keeps the operation
/// reusable until it finishes or the provider explicitly shuts down transport.
@MainActor
final class CloudTerminalProjectionRegistry {
    private(set) var tasks: [String: CloudTerminalProjectionTask] = [:]

    func task(
        for key: String,
        operation: @escaping @MainActor () async throws -> SurfaceRemotePlacement
    ) -> CloudTerminalProjectionTask {
        if let existing = tasks[key] { return existing }
        let token = UUID()
        let completion = CloudProjectionCompletion()
        let sharedTask = Task<SurfaceRemotePlacement, Error> { @MainActor [weak self] in
            defer { self?.finish(key: key, token: token) }
            do {
                try Task.checkCancellation()
                let placement = try await operation()
                completion.resolve(.success(placement))
                return placement
            } catch {
                completion.resolve(.failure(error))
                throw error
            }
        }
        let shared = CloudTerminalProjectionTask(token: token, task: sharedTask, completion: completion)
        // This synchronous MainActor turn registers before the operation runs.
        tasks[key] = shared
        return shared
    }

    func cancelAll() {
        for shared in tasks.values {
            shared.completion.resolve(.failure(CancellationError()))
            shared.task.cancel()
        }
        tasks.removeAll()
    }

    func awaitValue(_ shared: CloudTerminalProjectionTask) async throws -> SurfaceRemotePlacement {
        try await shared.completion.value()
    }

    private func finish(key: String, token: UUID) {
        guard tasks[key]?.token == token else { return }
        tasks[key] = nil
    }
}
