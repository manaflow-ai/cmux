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
    private typealias PendingUpdate = (
        workspaceID: UUID,
        capture: @MainActor () -> SessionTodoStateSnapshot?
    )

    private let queue: DispatchQueue
    private let snapshotStore: any SessionSnapshotStoring<AppSessionSnapshot>
    private let fallbackSave: @MainActor () -> Bool
    private var pending: [UUID: PendingUpdate] = [:]
    private var activeUpdates: [PendingUpdate] = []
    private var writeTimer: DispatchSourceTimer?
    private var writeInFlight = false
    private var consecutiveFailures = 0
    private var terminalFailure = false

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
        pending[workspaceID] = (
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
        scheduleWriteIfNeeded(resetDelay: true)
    }

    private func scheduleWriteIfNeeded(
        after requestedDelay: DispatchTimeInterval? = nil,
        resetDelay: Bool = false
    ) {
        if resetDelay {
            writeTimer?.cancel()
            writeTimer = nil
        }
        guard !writeInFlight, !pending.isEmpty, writeTimer == nil, !terminalFailure else { return }
        // Keep the live model responsive while giving normal typing pauses
        // enough room to collapse into one full-session snapshot write.
        let delay = requestedDelay ?? .milliseconds(500)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.writeTimer?.cancel()
                self?.writeTimer = nil
                self?.startWrite()
            }
        }
        writeTimer = timer
        timer.resume()
    }

    private func startWrite() {
        guard !writeInFlight, !pending.isEmpty, writeTimer == nil, !terminalFailure else { return }
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
            let saveSucceeded: Bool
            if var snapshot = snapshotStore.load(fileURL: nil) {
                var allUpdatesApplied = true
                for update in updates {
                    allUpdatesApplied = update.apply(to: &snapshot) && allUpdatesApplied
                }
                if allUpdatesApplied {
                    saveSucceeded = snapshotStore.save(snapshot, fileURL: nil)
                } else {
                    saveSucceeded = false
                }
            } else {
                saveSucceeded = false
            }
            let didSave = saveSucceeded
            Task { @MainActor [weak self] in
                self?.finishWrite(saveSucceeded: didSave)
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
            // The full snapshot captured the current live workspaces, so the
            // incremental updates that led here are now represented or no
            // longer applicable because their workspace was closed.
            pending.removeAll(keepingCapacity: true)
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
