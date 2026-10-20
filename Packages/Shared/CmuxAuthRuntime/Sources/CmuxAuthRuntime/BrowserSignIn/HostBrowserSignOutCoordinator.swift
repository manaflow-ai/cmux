import Foundation

@MainActor
final class HostBrowserSignOutCoordinator {
    private let beginSignOut: @MainActor @Sendable () -> Void
    private let localSignOut: @MainActor @Sendable () async -> Void
    private let signOut: @MainActor @Sendable (UInt64?) async -> Void
    private let currentGeneration: @MainActor @Sendable () -> UInt64
    private var nextOperationID: UInt64 = 0
    private var activeOperation: (id: UInt64, task: Task<Void, Never>)?

    init(
        beginSignOut: @escaping @MainActor @Sendable () -> Void,
        localSignOut: @escaping @MainActor @Sendable () async -> Void,
        currentGeneration: @escaping @MainActor @Sendable () -> UInt64,
        signOut: @escaping @MainActor @Sendable (UInt64?) async -> Void
    ) {
        self.beginSignOut = beginSignOut
        self.localSignOut = localSignOut
        self.signOut = signOut
        self.currentGeneration = currentGeneration
    }

    func joinActive() async -> Bool {
        guard let activeOperation else { return false }
        await activeOperation.task.value
        return true
    }

    func run(ifGeneration expectedGeneration: UInt64? = nil) async {
        if let activeOperation {
            await activeOperation.task.value
            return
        }
        nextOperationID &+= 1
        let operationID = nextOperationID
        let task = Task { @MainActor [beginSignOut, localSignOut, signOut, currentGeneration] in
            if let expectedGeneration, expectedGeneration != currentGeneration() { return }
            beginSignOut()
            async let localCleanup: Void = localSignOut()
            await signOut(expectedGeneration)
            await localCleanup
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
