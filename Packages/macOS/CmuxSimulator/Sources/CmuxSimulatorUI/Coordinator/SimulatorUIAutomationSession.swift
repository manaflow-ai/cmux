import CmuxSimulator
import Foundation

/// Stores pane-scoped refs and serializes Simulator UI mutations.
@MainActor
final class SimulatorUIAutomationSession {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var record: SimulatorUIAutomationSnapshotRecord?
    private var nextSequence: UInt64 = 1
    private var transactionIsActive = false
    private var waiters: [Waiter] = []

    func withTransaction<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        try await acquireTransaction()
        defer { releaseTransaction() }
        return try await operation()
    }

    func record(
        _ snapshot: SimulatorAccessibilitySnapshot,
        simulatorID: String,
        capturedAtMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        let newRecord = try snapshot.uiAutomationRecord(
            simulatorID: simulatorID,
            sequence: nextSequence,
            capturedAtMilliseconds: capturedAtMilliseconds
        )
        nextSequence &+= 1
        record = newRecord
        return newRecord
    }

    func currentRecord(
        nowMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        guard let record else {
            throw SimulatorUIAutomationReferenceError.snapshotMissing
        }
        guard nowMilliseconds <= record.snapshot.expiresAtMilliseconds else {
            self.record = nil
            throw SimulatorUIAutomationReferenceError.snapshotExpired(
                ageMilliseconds: max(
                    0,
                    nowMilliseconds - record.snapshot.capturedAtMilliseconds
                )
            )
        }
        return record
    }

    func resolve(
        elementRef: String,
        requiredActions: [SimulatorUIAutomationActionName],
        nowMilliseconds: Int64
    ) throws -> SimulatorUIAutomationElementRecord {
        let record = try currentRecord(nowMilliseconds: nowMilliseconds)
        guard let element = record.element(ref: elementRef) else {
            throw SimulatorUIAutomationReferenceError.elementRefNotFound(elementRef)
        }
        guard requiredActions.isEmpty
                || requiredActions.contains(where: element.element.actions.contains) else {
            throw SimulatorUIAutomationReferenceError.targetNotActionable(
                ref: elementRef,
                required: requiredActions
            )
        }
        return element
    }

    func stableSelector(
        elementRef: String,
        nowMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSelector {
        let record = try currentRecord(nowMilliseconds: nowMilliseconds)
        guard record.element(ref: elementRef) != nil else {
            throw SimulatorUIAutomationReferenceError.elementRefNotFound(elementRef)
        }
        guard let selector = record.stableSelector(for: elementRef) else {
            throw SimulatorUIAutomationReferenceError.stableSelectorUnavailable(elementRef)
        }
        return selector
    }

    func clearSnapshot() {
        record = nil
    }

    func reset() {
        record = nil
        nextSequence = 1
    }

    func beginTransaction() async throws {
        try await acquireTransaction()
    }

    func endTransaction() {
        releaseTransaction()
    }

    private func acquireTransaction() async throws {
        try Task.checkCancellation()
        guard transactionIsActive else {
            transactionIsActive = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: id)
            }
        }
    }

    private func releaseTransaction() {
        guard !waiters.isEmpty else {
            transactionIsActive = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
