import Foundation

/// Owns read-your-writes state across provider replacement. Accepted states
/// publish synchronously in memory; one writer drains changed machine keys
/// off the UI actor, preserving order without timers or one task per event.
@MainActor
final class CloudNotificationSyncStore {
    private let defaults: UserDefaults
    private let persistence: CloudNotificationSyncPersistence
    private var states: [String: CloudNotificationSyncState] = [:]
    private var pending: [String: CloudNotificationSyncPersistence.Mutation] = [:]
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistence = CloudNotificationSyncPersistence(defaults: defaults)
    }

    static func key(machineID: String) -> String { "cloud.notifications.sync.\(machineID)" }

    /// Loads each machine once. A replacement provider sees pending state,
    /// even while the persistence actor is still writing the previous batch.
    func load(machineID: String) -> CloudNotificationSyncState {
        if let state = states[machineID] { return state }
        let state = defaults.data(forKey: Self.key(machineID: machineID))
            .flatMap { try? JSONDecoder().decode(CloudNotificationSyncState.self, from: $0) }
            ?? CloudNotificationSyncState()
        states[machineID] = state
        return state
    }

    func save(_ state: CloudNotificationSyncState, machineID: String) {
        guard state != load(machineID: machineID) else { return }
        states[machineID] = state
        pending[Self.key(machineID: machineID)] = .save(state)
        startWriterIfNeeded()
    }

    func remove(machineID: String) {
        states[machineID] = CloudNotificationSyncState()
        pending[Self.key(machineID: machineID)] = .remove
        startWriterIfNeeded()
    }

    var hasPendingWrites: Bool { writeTask != nil }

    /// Checkpoints writes accepted before this call. Later machine updates must
    /// not keep an acknowledgement waiting for the entire fleet to go quiet.
    func flush() async {
        guard writeTask != nil else { return }
        await withCheckedContinuation { flushWaiters.append($0) }
    }

    /// Joins all outstanding batches before normal app termination.
    func drain() async {
        while let writeTask { await writeTask.value }
    }

    private func startWriterIfNeeded() {
        guard writeTask == nil else { return }
        writeTask = Task {
            while !pending.isEmpty || !flushWaiters.isEmpty {
                let batch = pending
                let waiters = flushWaiters
                pending.removeAll(keepingCapacity: true)
                flushWaiters.removeAll(keepingCapacity: true)
                await persistence.apply(batch)
                for waiter in waiters { waiter.resume() }
            }
            writeTask = nil
        }
    }
}
