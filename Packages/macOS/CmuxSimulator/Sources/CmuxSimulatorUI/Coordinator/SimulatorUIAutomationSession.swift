import CmuxSimulator
import Foundation

private enum SimulatorUIAutomationTransactionContext {
    @TaskLocal static var token: UUID?
}

/// Stores pane-scoped refs and serializes Simulator UI mutations.
@MainActor
final class SimulatorUIAutomationSession {
    private static let maximumQueuedTransactionCount = 8

    private var record: SimulatorUIAutomationSnapshotRecord?
    private var nextSequence: UInt64 = 1
    private(set) var mutationGeneration: UInt64 = 0
    private var retainedTouch: SimulatorUIAutomationHeldTouch?
    private var transactionIsActive = false
    private var activeTransactionToken: UUID?
    private var activeControlActionToken: UUID?
    private var waiters: [SimulatorUIAutomationTransactionWaiter] = []

    func withTransaction<T>(
        beforeOperation: @MainActor () async throws -> Void = {},
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        let token = UUID()
        try await acquireTransaction(
            token: token,
            controlActionToken: nil
        )
        defer { releaseTransaction() }
        try Task.checkCancellation()
        return try await SimulatorUIAutomationTransactionContext.$token.withValue(token) {
            try await beforeOperation()
            return try await operation()
        }
    }

    func record(
        _ snapshot: SimulatorAccessibilitySnapshot,
        simulatorID: String,
        capturedAtMilliseconds: Int64,
        expectedMutationGeneration: UInt64
    ) async throws -> SimulatorUIAutomationSnapshotRecord {
        guard mutationGeneration == expectedMutationGeneration else {
            throw SimulatorUIAutomationSnapshotRecordingError
                .invalidatedDuringPreparation
        }
        let reservedSequence = nextSequence
        nextSequence &+= 1
        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let prepared = try snapshot.uiAutomationRecord(
                simulatorID: simulatorID,
                sequence: reservedSequence,
                capturedAtMilliseconds: capturedAtMilliseconds
            )
            try Task.checkCancellation()
            return prepared
        }
        let newRecord = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        guard mutationGeneration == expectedMutationGeneration else {
            throw SimulatorUIAutomationSnapshotRecordingError
                .invalidatedDuringPreparation
        }
        if (record?.snapshot.sequence ?? 0) <= reservedSequence {
            record = newRecord
        }
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
        guard record.matching(selector).count == 1 else {
            throw SimulatorUIAutomationReferenceError.stableSelectorAmbiguous(elementRef)
        }
        return selector
    }

    func clearSnapshot() {
        record = nil
        mutationGeneration &+= 1
    }

    func restoreSnapshot(_ record: SimulatorUIAutomationSnapshotRecord) {
        self.record = record
    }

    func reset() {
        record = nil
        retainedTouch = nil
        mutationGeneration &+= 1
    }

    func holdTouch(
        elementRef: String,
        point: SimulatorPoint,
        display: SimulatorDisplayMetadata?
    ) {
        retainedTouch = SimulatorUIAutomationHeldTouch(
            elementRef: elementRef,
            point: point,
            display: display
        )
    }

    func heldTouch(
        elementRef: String
    ) -> SimulatorUIAutomationHeldTouch? {
        guard retainedTouch?.elementRef == elementRef else { return nil }
        return retainedTouch
    }

    var hasHeldTouch: Bool {
        retainedTouch != nil
    }

    func releaseHeldTouch(elementRef: String) {
        guard retainedTouch?.elementRef == elementRef else { return }
        retainedTouch = nil
    }

    func releaseAllHeldTouches() {
        retainedTouch = nil
    }

    func beginTransaction(controlActionToken: UUID? = nil) async throws {
        try await acquireTransaction(
            token: UUID(),
            controlActionToken: controlActionToken
        )
        do {
            try Task.checkCancellation()
        } catch {
            releaseTransaction()
            throw error
        }
    }

    func endTransaction() {
        releaseTransaction()
    }

    var isTransactionActive: Bool {
        transactionIsActive
    }

    func currentTaskOwnsTransaction(controlActionToken: UUID?) -> Bool {
        if let activeTransactionToken,
           SimulatorUIAutomationTransactionContext.token == activeTransactionToken {
            return true
        }
        guard let activeControlActionToken else { return false }
        return controlActionToken == activeControlActionToken
    }

    private func acquireTransaction(
        token: UUID,
        controlActionToken: UUID?
    ) async throws {
        try Task.checkCancellation()
        guard transactionIsActive else {
            transactionIsActive = true
            activeTransactionToken = token
            activeControlActionToken = controlActionToken
            return
        }
        guard waiters.count < Self.maximumQueuedTransactionCount else {
            throw SimulatorUIAutomationTransactionError.busy
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(SimulatorUIAutomationTransactionWaiter(
                        id: id,
                        token: token,
                        controlActionToken: controlActionToken,
                        continuation: continuation
                    ))
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
            activeTransactionToken = nil
            activeControlActionToken = nil
            return
        }
        let waiter = waiters.removeFirst()
        activeTransactionToken = waiter.token
        activeControlActionToken = waiter.controlActionToken
        waiter.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
