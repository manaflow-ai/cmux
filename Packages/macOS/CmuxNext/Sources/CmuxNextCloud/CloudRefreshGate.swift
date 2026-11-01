import Foundation

/// Shares overlapping Cloud refresh triggers and keeps one latest follow-up.
/// CloudService is main-actor isolated, so the gate needs no additional lock.
@MainActor
public final class CloudRefreshGate {
    private var active: Task<Bool, Never>?
    private var activeID: UInt64?
    private var nextID: UInt64 = 0
    private var followUpRequested = false

    public init() {}

    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let active {
            followUpRequested = true
            return await withTaskCancellationHandler(operation: { await active.value }, onCancel: { active.cancel() })
        }

        followUpRequested = false
        nextID &+= 1
        let id = nextID
        let task = Task { @MainActor () -> Bool in
            await operation()
        }
        active = task
        activeID = id
        var result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        // concurrency-allow: one bounded follow-up follows the awaited refresh when a caller arrived during it.
        if followUpRequested, !Task.isCancelled {
            followUpRequested = false
            result = await operation()
        }
        if activeID == id {
            active = nil
            activeID = nil
        }
        return result
    }
}
