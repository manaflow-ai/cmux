import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Waits for the connection to be ready again: the event that lets a request that found no connection, or lost
/// it, be sent again (a keyed browser-tab create). `connectOnce` resumes the waits when a connection is admitted,
/// `close()` and a permanent reconnect failure end them, and each has a limit on the connection's clock.
extension DaemonConnection {
    /// True once a connection newer than `serial` (nil: any) is ready; false when the connection closed for good,
    /// `limit` passed on ``clock`` or the task was cancelled.
    func untilReady(after serial: UInt64?, within limit: Duration) async -> Bool {
        if let ready, ready.serial > serial ?? 0 { return true }
        if isClosedPhase || Task.isCancelled || limit <= .zero { return false }
        readyWaitNext &+= 1
        let key = readyWaitNext
        // timer-class-allow: off main: the wait's limit resumes it on the connection's actor; no main-thread job
        let timer = DemandTimer(owner: "DaemonConnection.readyWait", clock: clock)
        return await withTaskCancellationHandler {
            // A wait dropped unresumed is not ready, as one past its limit is.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                readyWaits[key] = (serial ?? 0, continuation, timer)
                timer.schedule(after: limit) { [weak self] in await self?.endReadyWait(key) }
            }) ?? false
        } onCancel: {
            // task-owner: one hop back to the actor to resume this cancelled wait's continuation
            Task { await self.endReadyWait(key) }
        }
    }

    /// Resumes the waits a newly admitted connection `serial` satisfies.
    func resumeReadyWaits(serial: UInt64) {
        let due = readyWaits.filter { $0.value.after < serial }
        for (key, wait) in due {
            readyWaits[key] = nil
            wait.timer.cancel()
            wait.continuation.resume(returning: true)
        }
    }

    /// The connection closed for good: every wait resumes with false.
    func endReadyWaits() {
        let waits = readyWaits
        readyWaits.removeAll()
        for wait in waits.values {
            wait.timer.cancel()
            wait.continuation.resume(returning: false)
        }
    }

    private func endReadyWait(_ key: UInt64) {
        guard let wait = readyWaits.removeValue(forKey: key) else { return }
        wait.timer.cancel()
        wait.continuation.resume(returning: false)
    }
}
