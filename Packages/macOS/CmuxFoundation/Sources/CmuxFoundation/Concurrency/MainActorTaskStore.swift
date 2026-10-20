import os

/// Coordinates keyed tasks without strongly retaining their task handles.
///
/// A private owner keeps each handle alive until its task completes, while the
/// store holds that owner weakly for cancellation. The task captures this store
/// weakly for completion cleanup. A value snapshot can therefore retain the
/// store, but the store cannot retain the snapshot through the task.
@MainActor
public final class MainActorTaskStore<Key: Hashable & Sendable> {
    /// Self-retained by its task until completion clears the handle.
    ///
    /// Safety: every handle access is serialized by `taskState`, so cancellation
    /// from a nonisolated store deinitializer cannot race task completion.
    private final class TaskOwner: @unchecked Sendable {
        private struct State: Sendable {
            var task: Task<Void, Never>?
            var isCancelled = false
            var isFinished = false
        }

        private let taskState = OSAllocatedUnfairLock(initialState: State())

        func install(_ newTask: Task<Void, Never>) {
            let shouldCancel = taskState.withLock { state in
                guard !state.isFinished else { return false }
                state.task = newTask
                return state.isCancelled
            }
            if shouldCancel { newTask.cancel() }
        }

        func cancel() {
            let currentTask = taskState.withLock { state in
                state.isCancelled = true
                return state.task
            }
            currentTask?.cancel()
        }

        func releaseTask() {
            taskState.withLock { state in
                state.isFinished = true
                state.task = nil
            }
        }
    }

    /// Safety: weak-reference loads are runtime synchronized, and instances of
    /// this wrapper are otherwise accessed only inside `TaskOwnerRegistry`'s
    /// lock.
    private struct WeakTaskOwner: @unchecked Sendable {
        weak var value: TaskOwner?
    }

    /// Nonisolated weak-owner index used solely for cancellation.
    ///
    /// Safety: `owners` serializes every mutation and snapshot. The registry
    /// never owns a task or operation strongly.
    private final class TaskOwnerRegistry: @unchecked Sendable {
        private let owners = OSAllocatedUnfairLock(
            initialState: [UInt64: WeakTaskOwner]()
        )

        func install(_ owner: TaskOwner, generation: UInt64) {
            owners.withLock { $0[generation] = WeakTaskOwner(value: owner) }
        }

        func cancelAndRemove(generation: UInt64) {
            let owner = owners.withLock { $0.removeValue(forKey: generation)?.value }
            owner?.cancel()
        }

        func remove(generation: UInt64) {
            _ = owners.withLock { $0.removeValue(forKey: generation) }
        }

        func cancelAll() {
            let liveOwners = owners.withLock { owners in
                let liveOwners = owners.values.compactMap(\.value)
                owners.removeAll()
                return liveOwners
            }
            for owner in liveOwners {
                owner.cancel()
            }
        }
    }

    private struct Entry: Sendable {
        let generation: UInt64
    }

    private nonisolated let taskOwners = TaskOwnerRegistry()
    private var entries: [Key: Entry] = [:]
    private var nextGeneration: UInt64 = 0

    /// Creates an empty task store.
    public init() {}

    /// Returns whether `key` currently has a running or reserved task.
    ///
    /// - Parameter key: The task slot to inspect.
    /// - Returns: `true` while the slot coordinates a current operation.
    public func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// Replaces a task that may run away from the main actor.
    ///
    /// Replacement cancels the predecessor before constructing the successor.
    /// Completion removes the slot only when its generation is still current.
    ///
    /// - Parameters:
    ///   - key: The task slot to replace.
    ///   - priority: The priority inherited by the operation task.
    ///   - operation: Asynchronous work to run until completion or replacement.
    public func replace(
        _ key: Key,
        priority: TaskPriority? = nil,
        with operation: @escaping @Sendable () async -> Void
    ) {
        let (generation, owner) = prepareReplacement(key)
        let task = Task.detached(priority: priority) { [weak self, owner] in
            await operation()
            owner.releaseTask()
            await self?.finish(key, generation: generation)
        }
        owner.install(task)
    }

    /// Replaces a task whose operation must remain main-actor isolated.
    ///
    /// - Parameters:
    ///   - key: The task slot to replace.
    ///   - priority: The priority inherited by the operation task.
    ///   - operation: Main-actor work to run until completion or replacement.
    public func replaceOnMainActor(
        _ key: Key,
        priority: TaskPriority? = nil,
        with operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let (generation, owner) = prepareReplacement(key)
        let task = Task(priority: priority) { @MainActor [weak self, owner] in
            await operation()
            owner.releaseTask()
            self?.finish(key, generation: generation)
        }
        owner.install(task)
    }

    /// Cancels and releases the operation coordinated for `key`, if any.
    ///
    /// - Parameter key: The task slot to cancel.
    public func cancel(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        taskOwners.cancelAndRemove(generation: entry.generation)
    }

    /// Cancels every operation whose key matches `predicate`.
    ///
    /// - Parameter predicate: Returns `true` for each slot to cancel.
    public func cancel(where predicate: (Key) -> Bool) {
        let keys = entries.keys.filter(predicate)
        for key in keys {
            cancel(key)
        }
    }

    private func prepareReplacement(_ key: Key) -> (UInt64, TaskOwner) {
        cancel(key)
        nextGeneration &+= 1
        let generation = nextGeneration
        let owner = TaskOwner()
        entries[key] = Entry(generation: generation)
        taskOwners.install(owner, generation: generation)
        return (generation, owner)
    }

    private func finish(_ key: Key, generation: UInt64) {
        taskOwners.remove(generation: generation)
        guard entries[key]?.generation == generation else { return }
        entries.removeValue(forKey: key)
    }

    deinit {
        taskOwners.cancelAll()
    }
}
