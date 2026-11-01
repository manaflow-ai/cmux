import Foundation

/// Shares overlapping Cloud refresh triggers and keeps one latest follow-up.
/// CloudService is main-actor isolated, so the gate needs no additional lock.
@MainActor
public final class CloudRefreshGate {
    private var active: Task<Bool, Never>?
    private var followUpRequested = false

    public init() {}

    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let active {
            followUpRequested = true
            return await withTaskCancellationHandler(operation: { await active.value }, onCancel: { active.cancel() })
        }

        followUpRequested = false
        let task = Task { @MainActor () -> Bool in
            await operation()
        }
        active = task
        var result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        // concurrency-allow: one bounded follow-up follows the awaited refresh when a caller arrived during it.
        if followUpRequested, !Task.isCancelled {
            followUpRequested = false
            result = await operation()
        }
        active = nil
        return result
    }
}
