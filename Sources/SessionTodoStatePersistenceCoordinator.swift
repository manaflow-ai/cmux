import Foundation
import os

private let sessionTodoPersistenceLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "SessionTodoPersistence"
)

/// Debounces live todo edits before asking the session persistence owner to
/// capture the complete current in-memory session.
@MainActor
final class SessionTodoStatePersistenceCoordinator {
    private let saveSnapshot: @MainActor () -> Bool
    private var writeTimer: DispatchSourceTimer?
    private var hasPendingEdits = false
    private var consecutiveFailures = 0
    private var terminalFailure = false

    private static let maximumRetryCount = 3

    init(saveSnapshot: @escaping @MainActor () -> Bool) {
        self.saveSnapshot = saveSnapshot
    }

    func enqueue() {
        hasPendingEdits = true
        if terminalFailure {
            terminalFailure = false
            consecutiveFailures = 0
        }
        scheduleWrite(resetDelay: true)
    }

    private func scheduleWrite(
        after requestedDelay: DispatchTimeInterval? = nil,
        resetDelay: Bool = false
    ) {
        if resetDelay {
            writeTimer?.cancel()
            writeTimer = nil
        }
        guard hasPendingEdits, writeTimer == nil, !terminalFailure else { return }
        let delay = requestedDelay ?? .milliseconds(500)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.writeTimer?.cancel()
                self?.writeTimer = nil
                self?.flushPendingEdits()
            }
        }
        writeTimer = timer
        timer.resume()
    }

    private func flushPendingEdits() {
        guard hasPendingEdits, !terminalFailure else { return }
        hasPendingEdits = false
        guard saveSnapshot() else {
            hasPendingEdits = true
            consecutiveFailures += 1
            if consecutiveFailures <= Self.maximumRetryCount {
                let delay = DispatchTimeInterval.milliseconds(100 * (1 << (consecutiveFailures - 1)))
                scheduleWrite(after: delay)
            } else {
                terminalFailure = true
                sessionTodoPersistenceLogger.error(
                    "Todo session persistence stopped after repeated snapshot failures"
                )
            }
            return
        }
        consecutiveFailures = 0
        scheduleWrite()
    }
}
