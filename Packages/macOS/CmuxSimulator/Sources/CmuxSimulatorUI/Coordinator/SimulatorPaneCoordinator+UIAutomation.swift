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
        return try await uiAutomationSession.withTransaction(operation)
    }

    /// Acquires the pane UI transaction for a legacy operation that can move the screen.
    ///
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    public func beginUIAutomationTransaction() async throws {
        try await uiAutomationSession.beginTransaction(
            controlActionToken: currentControlActionTaskToken
        )
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
    ///   - expectedMutationGeneration: The pane generation before capture began.
    /// - Returns: The public snapshot and its lookup metadata.
    /// - Throws: When no root has a usable viewport, the task is cancelled, or the pane
    ///   changes before the prepared snapshot can be committed.
    public func recordUIAutomationSnapshot(
        _ snapshot: SimulatorAccessibilitySnapshot,
        simulatorID: String,
        capturedAtMilliseconds: Int64,
        expectedMutationGeneration: UInt64
    ) async throws -> SimulatorUIAutomationSnapshotRecord {
        try await uiAutomationSession.record(
            snapshot,
            simulatorID: simulatorID,
            capturedAtMilliseconds: capturedAtMilliseconds,
            expectedMutationGeneration: expectedMutationGeneration
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
    ///   - ref: The current snapshot-scoped reference.
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
    ///   - ref: The current snapshot-scoped reference.
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

    /// Restores a still-valid record when an unchanged poll omits replacement refs.
    public func restoreUIAutomationSnapshot(
        _ record: SimulatorUIAutomationSnapshotRecord
    ) {
        uiAutomationSession.restoreSnapshot(record)
    }

    /// Current generation of UI mutations observed by this pane.
    public var uiAutomationMutationGeneration: UInt64 {
        uiAutomationSession.mutationGeneration
    }

    /// Retains a down-only semantic touch independently from snapshot refs.
    public func holdUIAutomationTouch(
        elementRef: String,
        point: SimulatorPoint,
        display: SimulatorDisplayMetadata?
    ) {
        uiAutomationSession.holdTouch(
            elementRef: elementRef,
            point: point,
            display: display
        )
    }

    /// Returns a held semantic touch only for its original ref.
    public func heldUIAutomationTouch(
        elementRef: String
    ) -> SimulatorUIAutomationHeldTouch? {
        uiAutomationSession.heldTouch(elementRef: elementRef)
    }

    /// Whether this pane currently owns a retained semantic touch contact.
    public var hasHeldUIAutomationTouch: Bool {
        uiAutomationSession.hasHeldTouch
    }

    /// Whether one pointer operation may use the worker's single touch owner.
    ///
    /// Only the coordinated release for the retained semantic touch may bypass
    /// ownership. Live input and every new gesture must wait for that release.
    public func admitsSimulatorPointerInput(
        releasingHeldUIAutomationTouch: Bool = false
    ) -> Bool {
        !uiAutomationSession.hasHeldTouch || releasingHeldUIAutomationTouch
    }

    /// Clears a held semantic touch after its release reaches the worker.
    public func releaseHeldUIAutomationTouch(elementRef: String) {
        uiAutomationSession.releaseHeldTouch(elementRef: elementRef)
    }

    /// Clears retained semantic contact when worker input state is released.
    func releaseAllHeldUIAutomationTouches() {
        uiAutomationSession.releaseAllHeldTouches()
    }

    /// Resets refs and sequence when this pane changes devices.
    public func resetUIAutomationSession() {
        uiAutomationSession.reset()
    }
}

extension SimulatorInteractiveAction {
    var usesSimulatorPointerInput: Bool {
        switch self {
        case .gesture, .timedGesture, .touch:
            true
        case .keyPresses, .keyChord, .typeText, .hardwareButton,
             .hardwareButtonHold, .rotate, .coreAnimation, .memoryWarning:
            false
        }
    }

    var releasesRetainedSimulatorPointerOnly: Bool {
        guard case let .touch(events, _) = self, !events.isEmpty else {
            return false
        }
        return events.allSatisfy { event in
            event.phase == .ended || event.phase == .cancelled
        }
    }
}

extension SimulatorControlAction {
    var usesSimulatorPointerInput: Bool {
        guard case let .interactive(action) = self else { return false }
        return action.usesSimulatorPointerInput
    }

    var releasesRetainedSimulatorPointerOnly: Bool {
        guard case let .interactive(action) = self else { return false }
        return action.releasesRetainedSimulatorPointerOnly
    }
}

extension SimulatorWorkerInbound {
    var usesUnownedSimulatorPointerInput: Bool {
        switch self {
        case .pointer, .scrollWheel:
            true
        case let .interactiveAction(_, action):
            action.usesSimulatorPointerInput
        default:
            false
        }
    }
}
