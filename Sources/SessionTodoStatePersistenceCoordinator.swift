import CmuxWorkspaces
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
    private var scheduledWrite: Task<Void, Never>?

    private static let coalescingDelay: Duration = .milliseconds(100)

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
        guard !writeInFlight, !pending.isEmpty, scheduledWrite == nil else { return }
        scheduledWrite = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.coalescingDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.scheduledWrite = nil
            self.startWrite()
        }
    }

    private func startWrite() {
        guard !writeInFlight, !pending.isEmpty else { return }
        writeInFlight = true
        let updates = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        let snapshotStore = snapshotStore

        queue.async { [weak self] in
            var saveSucceeded = false
            if var snapshot = snapshotStore.load(fileURL: nil) {
                for update in updates {
                    _ = update.apply(to: &snapshot)
                }
                saveSucceeded = snapshotStore.save(snapshot, fileURL: nil)
            } else {
                Task { @MainActor [weak self] in
                    self?.requestFallbackSaveIfNeeded()
                }
            }
            Task { @MainActor [weak self] in
                self?.finishWrite(updates: updates, saveSucceeded: saveSucceeded)
            }
        }
    }

    private func finishWrite(updates: [SessionTodoStateSnapshot], saveSucceeded: Bool) {
        if !saveSucceeded {
            for update in updates where pending[update.workspaceID] == nil {
                pending[update.workspaceID] = update
            }
        }
        writeInFlight = false
        scheduleWriteIfNeeded()
    }

    private func requestFallbackSaveIfNeeded() {
        guard !fallbackRequested else { return }
        fallbackRequested = true
        fallbackSave()
    }
}
