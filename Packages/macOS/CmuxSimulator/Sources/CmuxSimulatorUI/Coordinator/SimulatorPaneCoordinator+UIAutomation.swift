import CmuxSimulator

extension SimulatorPaneCoordinator {
    /// Serializes semantic UI work for this pane so refs cannot race a mutation.
    ///
    /// - Parameter operation: The main-actor operation to serialize.
    /// - Returns: The operation result.
    /// - Throws: Cancellation or the operation's failure.
    public func withUIAutomationTransaction<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        try await uiAutomationSession.withTransaction(operation)
    }

    /// Acquires the pane UI transaction for a legacy operation that can move the screen.
    ///
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    public func beginUIAutomationTransaction() async throws {
        try await uiAutomationSession.beginTransaction()
    }

    /// Releases a transaction acquired by ``beginUIAutomationTransaction()``.
    public func endUIAutomationTransaction() {
        uiAutomationSession.endTransaction()
    }

    /// Records a fresh compact snapshot and advances this pane's ref sequence.
    ///
    /// - Parameters:
    ///   - snapshot: The native accessibility snapshot.
    ///   - simulatorID: The selected CoreSimulator device identifier.
    ///   - capturedAtMilliseconds: The capture time in Unix epoch milliseconds.
    /// - Returns: The public snapshot and its lookup metadata.
    /// - Throws: ``SimulatorUIAutomationSnapshotError/viewportUnavailable`` when no root
    ///   has a usable viewport.
    public func recordUIAutomationSnapshot(
        _ snapshot: SimulatorAccessibilitySnapshot,
        simulatorID: String,
        capturedAtMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        try uiAutomationSession.record(
            snapshot,
            simulatorID: simulatorID,
            capturedAtMilliseconds: capturedAtMilliseconds
        )
    }

    /// Returns the current unexpired compact snapshot.
    ///
    /// - Parameter nowMilliseconds: The current Unix epoch time in milliseconds.
    /// - Returns: The current snapshot record.
    /// - Throws: ``SimulatorUIAutomationReferenceError`` when missing or expired.
    public func currentUIAutomationSnapshot(
        nowMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        try uiAutomationSession.currentRecord(nowMilliseconds: nowMilliseconds)
    }

    /// Resolves one current element ref and verifies its action contract.
    ///
    /// - Parameters:
    ///   - ref: The current process-scoped reference.
    ///   - requiredActions: Actions of which at least one must be advertised.
    ///   - nowMilliseconds: The current Unix epoch time in milliseconds.
    /// - Returns: The target and its process-local lookup metadata.
    /// - Throws: ``SimulatorUIAutomationReferenceError`` for stale or invalid targets.
    public func resolveUIAutomationElement(
        ref: String,
        requiredActions: [SimulatorUIAutomationActionName],
        nowMilliseconds: Int64
    ) throws -> SimulatorUIAutomationElementRecord {
        try uiAutomationSession.resolve(
            elementRef: ref,
            requiredActions: requiredActions,
            nowMilliseconds: nowMilliseconds
        )
    }

    /// Converts a current ref into exact semantic fields for a refreshed wait.
    ///
    /// - Parameters:
    ///   - ref: The current process-scoped reference.
    ///   - nowMilliseconds: The current Unix epoch time in milliseconds.
    /// - Returns: The strongest exact selector available.
    /// - Throws: ``SimulatorUIAutomationReferenceError`` for stale or unstable targets.
    public func stableUIAutomationSelector(
        ref: String,
        nowMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSelector {
        try uiAutomationSession.stableSelector(
            elementRef: ref,
            nowMilliseconds: nowMilliseconds
        )
    }

    /// Invalidates refs after a UI mutation.
    public func clearUIAutomationSnapshot() {
        uiAutomationSession.clearSnapshot()
    }

    /// Resets refs and sequence when this pane changes devices.
    public func resetUIAutomationSession() {
        uiAutomationSession.reset()
    }
}
