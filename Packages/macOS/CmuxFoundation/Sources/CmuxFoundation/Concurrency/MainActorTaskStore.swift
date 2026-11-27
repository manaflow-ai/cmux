import os

/// Self-retained by its task until completion clears the handle.
///
/// Non-generic on purpose: store teardown runs on whichever thread releases
/// the store (usually main), and must not instantiate per-`Key` generic
/// metadata or key paths there.
///
/// Safety: every handle access is serialized by `taskState`, so cancellation
/// from a nonisolated store deinitializer cannot race task completion.
final class MainActorTaskStoreOwner: @unchecked Sendable {
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

/// Nonisolated weak-owner index used solely for cancellation.
///
/// The lock guards only dictionary mutation: weak loads, owner releases and
/// `Task.cancel()` (which takes the runtime's task-status lock and runs
/// cancellation handlers synchronously) all happen after it is released, so
/// teardown never waits on this lock behind other work.
///
/// Safety: `owners` serializes every mutation and snapshot. The registry
/// never owns a task or operation strongly.
final class MainActorTaskStoreOwnerRegistry: @unchecked Sendable {
    /// Safety: weak-reference loads are runtime synchronized, and instances
    /// of this wrapper are otherwise accessed only inside the registry lock
    /// or in a snapshot no other thread can reach.
    struct WeakOwner: @unchecked Sendable {
        weak var value: MainActorTaskStoreOwner?
    }

    let owners = OSAllocatedUnfairLock(
        initialState: [UInt64: WeakOwner]()
    )

    func install(_ owner: MainActorTaskStoreOwner, generation: UInt64) {
        let weakOwner = WeakOwner(value: owner)
        owners.withLock { $0[generation] = weakOwner }
    }

    func cancelAndRemove(generation: UInt64) {
        let removed = owners.withLock { $0.removeValue(forKey: generation) }
        removed?.value?.cancel()
    }

    func remove(generation: UInt64) {
        let removed = owners.withLock { $0.removeValue(forKey: generation) }
        _ = removed
    }

    func cancelAll() {
        let drained = owners.withLock { owners in
            var drained: [UInt64: WeakOwner] = [:]
            swap(&drained, &owners)
            return drained
        }
        for weakOwner in drained.values {
            weakOwner.value?.cancel()
        }
    }
}

/// Coordinates keyed tasks without strongly retaining their task handles.
///
/// A private owner keeps each handle alive until its task completes, while the
/// store holds that owner weakly for cancellation. The task captures this store
/// weakly for completion cleanup. A value snapshot can therefore retain the
/// store, but the store cannot retain the snapshot through the task.
///
/// The cancellation registry is created with the first task. SwiftUI builds a
/// throwaway `@State` default value on every view initialization, so a store
/// that never started a task must allocate nothing and tear down without
/// taking a lock.
@MainActor
public final class MainActorTaskStore<Key: Hashable & Sendable> {
    private struct Entry: Sendable {
        let generation: UInt64
    }

    /// Created with the first task. Read by the nonisolated deinitializer,
    /// which has exclusive access.
    private(set) var taskOwners: MainActorTaskStoreOwnerRegistry?
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
        taskOwners?.cancelAndRemove(generation: entry.generation)
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

    private func prepareReplacement(_ key: Key) -> (UInt64, MainActorTaskStoreOwner) {
        cancel(key)
        nextGeneration &+= 1
        let generation = nextGeneration
        let owner = MainActorTaskStoreOwner()
        entries[key] = Entry(generation: generation)
        let registry: MainActorTaskStoreOwnerRegistry
        if let taskOwners {
            registry = taskOwners
        } else {
            registry = MainActorTaskStoreOwnerRegistry()
            taskOwners = registry
        }
        registry.install(owner, generation: generation)
        return (generation, owner)
    }

    private func finish(_ key: Key, generation: UInt64) {
        taskOwners?.remove(generation: generation)
        guard entries[key]?.generation == generation else { return }
        entries.removeValue(forKey: key)
    }

    deinit {
        taskOwners?.cancelAll()
    }
}
