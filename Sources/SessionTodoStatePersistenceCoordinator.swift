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

    private static let maximumRetryCount = 3
    private static let recoveryRetryDelay: DispatchTimeInterval = .seconds(5)

    init(saveSnapshot: @escaping @MainActor () -> Bool) {
        self.saveSnapshot = saveSnapshot
    }

    func enqueue() {
        hasPendingEdits = true
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
        guard hasPendingEdits, writeTimer == nil else { return }
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
        guard hasPendingEdits else { return }
        hasPendingEdits = false
        guard saveSnapshot() else {
            hasPendingEdits = true
            consecutiveFailures += 1
            if consecutiveFailures <= Self.maximumRetryCount {
                let delay = DispatchTimeInterval.milliseconds(100 * (1 << (consecutiveFailures - 1)))
                scheduleWrite(after: delay)
            } else {
                consecutiveFailures = 0
                sessionTodoPersistenceLogger.error(
                    "Todo session persistence retrying after repeated snapshot failures"
                )
                scheduleWrite(after: Self.recoveryRetryDelay)
            }
            return
        }
        consecutiveFailures = 0
        scheduleWrite()
    }
}
