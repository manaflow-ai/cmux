import Foundation

/// Coalesces rapid todo edits into one pending snapshot per workspace and
/// keeps at most one session-file write in flight.
@MainActor
final class SessionTodoStatePersistenceCoordinator {
    private let queue: DispatchQueue
    private let snapshotStore: any SessionSnapshotStoring<AppSessionSnapshot>
    private let fallbackSave: @MainActor () -> Void
    private var pending: [UUID: SessionTodoStateSnapshot] = [:]
    private var writeInFlight = false
    private var fallbackRequested = false

    init(
        queue: DispatchQueue,
        snapshotStore: any SessionSnapshotStoring<AppSessionSnapshot>,
        fallbackSave: @escaping @MainActor () -> Void
    ) {
        self.queue = queue
        self.snapshotStore = snapshotStore
        self.fallbackSave = fallbackSave
    }

    func enqueue(_ update: SessionTodoStateSnapshot) {
        pending[update.workspaceID] = update
        scheduleWriteIfNeeded()
    }

    private func scheduleWriteIfNeeded() {
        guard !writeInFlight, !pending.isEmpty else { return }
        writeInFlight = true
        let updates = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        let snapshotStore = snapshotStore

        queue.async { [weak self] in
            if var snapshot = snapshotStore.load(fileURL: nil) {
                for update in updates {
                    _ = update.apply(to: &snapshot)
                }
                _ = snapshotStore.save(snapshot, fileURL: nil)
            } else {
                Task { @MainActor [weak self] in
                    self?.requestFallbackSaveIfNeeded()
                }
            }
            Task { @MainActor [weak self] in
                self?.finishWrite()
            }
        }
    }

    private func finishWrite() {
        writeInFlight = false
        scheduleWriteIfNeeded()
    }

    private func requestFallbackSaveIfNeeded() {
        guard !fallbackRequested else { return }
        fallbackRequested = true
        fallbackSave()
    }
}
