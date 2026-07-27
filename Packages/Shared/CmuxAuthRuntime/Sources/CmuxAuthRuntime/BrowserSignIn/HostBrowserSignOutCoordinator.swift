import Foundation

@MainActor
final class HostBrowserSignOutCoordinator {
    private let beginSignOut: @MainActor @Sendable () -> Void
    private let signOut: @Sendable () async -> Void
    private var nextOperationID: UInt64 = 0
    private var activeOperation: (id: UInt64, task: Task<Void, Never>)?

    init(
        beginSignOut: @escaping @MainActor @Sendable () -> Void,
        signOut: @escaping @Sendable () async -> Void
    ) {
        self.beginSignOut = beginSignOut
        self.signOut = signOut
    }

    func joinActive() async -> Bool {
        guard let activeOperation else { return false }
        await activeOperation.task.value
        return true
    }

    func run() async {
        if let activeOperation {
            await activeOperation.task.value
            return
        }
        nextOperationID &+= 1
        let operationID = nextOperationID
        let task = Task { @MainActor [beginSignOut, signOut] in
            beginSignOut()
            await signOut()
        }
        activeOperation = (operationID, task)
        await task.value
        if activeOperation?.id == operationID {
            activeOperation = nil
        }
    }
}

struct HostBrowserCallbackStateGenerator: Sendable {
    func make() -> String {
        UUID().uuidString.lowercased()
    }
}

struct HostBrowserDeadline: Sendable {
    let clock: any Clock<Duration>

    /// Resolves `false` at the deadline without cancelling the underlying task.
    func resolve(_ attempt: Task<Bool, Never>, timeout: TimeInterval) async -> Bool {
        let clamped = max(0, min(timeout, 24 * 60 * 60))
        let stream = AsyncStream<Bool>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let deadlineTask = Task {
                do {
                    try await clock.sleep(for: .seconds(clamped))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                continuation.yield(false)
                continuation.finish()
            }
            let attemptWaitTask = Task {
                let result = await attempt.value
                continuation.yield(result)
                continuation.finish()
                deadlineTask.cancel()
            }
            continuation.onTermination = { @Sendable _ in
                deadlineTask.cancel()
                attemptWaitTask.cancel()
            }
        }
        for await result in stream {
            return result
        }
        return false
    }
}
