/// Coordinates keyed tasks without strongly retaining their task handles.
///
/// A private owner keeps each handle alive until its task completes, while the
/// store holds that owner weakly for cancellation. The task captures this store
/// weakly for completion cleanup. A value snapshot can therefore retain the
/// store, but the store cannot retain the snapshot through the task.
@MainActor
public final class MainActorTaskStore<Key: Hashable & Sendable> {
    /// Self-retained by its task until completion clears the handle.
    @MainActor
    private final class TaskOwner {
        private var task: Task<Void, Never>?

        func install(_ task: Task<Void, Never>) {
            self.task = task
        }

        func cancel() {
            task?.cancel()
        }

        func releaseTask() {
            task = nil
        }
    }

    private struct WeakTaskOwner {
        weak var value: TaskOwner?
    }

    private struct Entry {
        let generation: UInt64
        let owner: WeakTaskOwner
    }

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
            await owner.releaseTask()
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
        entries.removeValue(forKey: key)?.owner.value?.cancel()
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
        entries[key] = Entry(
            generation: generation,
            owner: WeakTaskOwner(value: owner)
        )
        return (generation, owner)
    }

    private func finish(_ key: Key, generation: UInt64) {
        guard entries[key]?.generation == generation else { return }
        entries.removeValue(forKey: key)
    }

    deinit {
        let owners = entries.values.compactMap(\.owner.value)
        guard !owners.isEmpty else { return }

        // Keep teardown compatible with older supported macOS runtimes while
        // moving actor-isolated cancellation off this nonisolated deinitializer.
        Task { @MainActor in
            for owner in owners {
                owner.cancel()
            }
        }
    }
}
