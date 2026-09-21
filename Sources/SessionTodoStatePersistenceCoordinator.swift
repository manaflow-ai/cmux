import CmuxWorkspaces
import Foundation
import os

private let sessionTodoPersistenceLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "SessionTodoPersistence"
)

/// Coalesces rapid todo edits before capturing a checklist snapshot and keeps
/// at most one session-file write in flight.
@MainActor
final class SessionTodoStatePersistenceCoordinator {
    private struct PendingUpdate {
        let workspaceID: UUID
        let capture: @MainActor () -> SessionTodoStateSnapshot?
    }

    private let queue: DispatchQueue
    private let snapshotStore: any SessionSnapshotStoring<AppSessionSnapshot>
    private let fallbackSave: @MainActor () -> Bool
    private var pending: [UUID: PendingUpdate] = [:]
    private var activeUpdates: [PendingUpdate] = []
    private var writeTimer: DispatchSourceTimer?
    private var writeInFlight = false
    private var consecutiveFailures = 0
    private var terminalFailure = false

    private static let coalescingDelay: DispatchTimeInterval = .milliseconds(100)
    private static let maximumRetryCount = 3

    init(
        queue: DispatchQueue,
        snapshotStore: any SessionSnapshotStoring<AppSessionSnapshot>,
        fallbackSave: @escaping @MainActor () -> Bool
    ) {
        self.queue = queue
        self.snapshotStore = snapshotStore
        self.fallbackSave = fallbackSave
    }

    func enqueue(workspace: Workspace) {
        let workspaceID = workspace.id
        pending[workspaceID] = PendingUpdate(
            workspaceID: workspaceID,
            capture: { [weak workspace] in
                guard let workspace else { return nil }
                return SessionTodoStateSnapshot(workspace: workspace)
            }
        )
        if terminalFailure {
            terminalFailure = false
            consecutiveFailures = 0
        }
        scheduleWriteIfNeeded()
    }

    private func scheduleWriteIfNeeded(after delay: DispatchTimeInterval = Self.coalescingDelay) {
        guard !writeInFlight, !pending.isEmpty, writeTimer == nil, !terminalFailure else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self, weak timer] in
            timer?.cancel()
            self?.writeTimer = nil
            self?.startWrite()
        }
        writeTimer = timer
        timer.resume()
    }

    private func startWrite() {
        guard !writeInFlight, !pending.isEmpty, !terminalFailure else { return }
        writeInFlight = true
        activeUpdates = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        let updates = activeUpdates.compactMap { $0.capture() }
        guard !updates.isEmpty else {
            activeUpdates.removeAll(keepingCapacity: true)
            writeInFlight = false
            scheduleWriteIfNeeded()
            return
        }
        let snapshotStore = snapshotStore

        queue.async { [weak self] in
            var saveSucceeded = false
            if var snapshot = snapshotStore.load(fileURL: nil) {
                for update in updates {
                    _ = update.apply(to: &snapshot)
                }
                saveSucceeded = snapshotStore.save(snapshot, fileURL: nil)
            }
            Task { @MainActor [weak self] in
                self?.finishWrite(saveSucceeded: saveSucceeded)
            }
        }
    }

    private func finishWrite(saveSucceeded: Bool) {
        let failedUpdates = activeUpdates
        activeUpdates.removeAll(keepingCapacity: true)
        writeInFlight = false

        guard !saveSucceeded else {
            consecutiveFailures = 0
            scheduleWriteIfNeeded()
            return
        }

        for update in failedUpdates where pending[update.workspaceID] == nil {
            pending[update.workspaceID] = update
        }
        consecutiveFailures += 1
        if consecutiveFailures <= Self.maximumRetryCount {
            let delay = DispatchTimeInterval.milliseconds(100 * (1 << (consecutiveFailures - 1)))
            scheduleWriteIfNeeded(after: delay)
            return
        }

        if fallbackSave() {
            consecutiveFailures = 0
            scheduleWriteIfNeeded()
        } else {
            terminalFailure = true
            sessionTodoPersistenceLogger.error(
                "Todo session persistence stopped after repeated snapshot failures"
            )
        }
    }
}
