import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator UI automation session")
struct SimulatorUIAutomationSessionTests {
    @Test("Refs resolve only from the current unexpired snapshot")
    func refLifetime() async throws {
        let session = SimulatorUIAutomationSession()
        let record = try await session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let ref = try #require(record.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)

        #expect(try session.resolve(
            elementRef: ref,
            requiredActions: [.tap],
            nowMilliseconds: 60_999
        ).element.identifier == "continue")
        #expect(throws: SimulatorUIAutomationReferenceError.snapshotExpired(
            ageMilliseconds: 60_001
        )) {
            _ = try session.resolve(
                elementRef: ref,
                requiredActions: [.tap],
                nowMilliseconds: 61_001
            )
        }
        #expect(throws: SimulatorUIAutomationReferenceError.snapshotMissing) {
            _ = try session.currentRecord(nowMilliseconds: 61_001)
        }
    }

    @Test("Action contracts and explicit invalidation reject stale refs")
    func actionContractAndInvalidation() async throws {
        let session = SimulatorUIAutomationSession()
        let record = try await session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let ref = try #require(record.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)

        #expect(throws: SimulatorUIAutomationReferenceError.targetNotActionable(
            ref: ref,
            required: [.typeText]
        )) {
            _ = try session.resolve(
                elementRef: ref,
                requiredActions: [.typeText],
                nowMilliseconds: 1_001
            )
        }

        session.clearSnapshot()
        #expect(throws: SimulatorUIAutomationReferenceError.snapshotMissing) {
            _ = try session.resolve(
                elementRef: ref,
                requiredActions: [.tap],
                nowMilliseconds: 1_002
            )
        }
    }

    @Test("A newer snapshot never rebinds an older ordinal ref")
    func replacementSnapshotInvalidatesOldRef() async throws {
        let session = SimulatorUIAutomationSession()
        let first = try await session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let oldRef = try #require(first.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)
        let second = try await session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 2_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let newRef = try #require(second.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)

        #expect(oldRef != newRef)
        #expect(throws: SimulatorUIAutomationReferenceError.elementRefNotFound(oldRef)) {
            _ = try session.resolve(
                elementRef: oldRef,
                requiredActions: [.tap],
                nowMilliseconds: 2_001
            )
        }
    }

    @Test("Refs cannot resolve in a different pane session")
    func refsAreNamespacedBySession() async throws {
        let firstSession = SimulatorUIAutomationSession()
        let secondSession = SimulatorUIAutomationSession()
        let first = try await firstSession.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: firstSession.mutationGeneration
        )
        let second = try await secondSession.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: secondSession.mutationGeneration
        )
        let firstRef = try #require(first.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)
        let secondRef = try #require(second.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)

        #expect(firstRef != secondRef)
        #expect(throws: SimulatorUIAutomationReferenceError.elementRefNotFound(firstRef)) {
            _ = try secondSession.resolve(
                elementRef: firstRef,
                requiredActions: [.tap],
                nowMilliseconds: 1_001
            )
        }
    }

    @Test("A ref-derived wait selector must identify one source element")
    func stableSelectorRejectsAmbiguousSource() async throws {
        let session = SimulatorUIAutomationSession()
        let record = try await session.record(
            snapshotWithDuplicateIdentifiers(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let ref = try #require(record.snapshot.elements.first {
            $0.identifier == "duplicate"
        }?.ref)

        do {
            _ = try session.stableSelector(
                elementRef: ref,
                nowMilliseconds: 1_001
            )
            Issue.record("Expected the duplicate source selector to be rejected")
        } catch {
            // Any failure is safer than silently rebinding this ref-derived wait.
        }
    }

    @Test("A truncated snapshot cannot provide a stable selector")
    func stableSelectorRejectsTruncatedSource() async throws {
        let session = SimulatorUIAutomationSession()
        let complete = snapshot()
        let truncated = SimulatorAccessibilitySnapshot(
            roots: complete.roots,
            display: complete.display,
            nodeCount: complete.nodeCount,
            isTruncated: true
        )
        let record = try await session.record(
            truncated,
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let ref = try #require(record.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)

        #expect(throws: SimulatorUIAutomationReferenceError.stableSelectorUnavailable(ref)) {
            _ = try session.stableSelector(
                elementRef: ref,
                nowMilliseconds: 1_001
            )
        }
    }

    @Test("A ref-derived wait selector requires an exact runtime identifier")
    func stableSelectorRejectsLabelOnlyIdentity() async throws {
        let session = SimulatorUIAutomationSession()
        let record = try await session.record(
            snapshotWithoutIdentifiers(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: session.mutationGeneration
        )
        let ref = try #require(record.snapshot.elements.first {
            $0.label == "Continue"
        }?.ref)

        #expect(throws: SimulatorUIAutomationReferenceError.stableSelectorUnavailable(ref)) {
            _ = try session.stableSelector(
                elementRef: ref,
                nowMilliseconds: 1_001
            )
        }
    }

    @Test("Recording and device reset preserve a monotonic sequence")
    func sequenceRemainsMonotonicAcrossReset() async throws {
        let session = SimulatorUIAutomationSession()
        #expect(try await session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1,
            expectedMutationGeneration: session.mutationGeneration
        ).snapshot.sequence == 1)
        #expect(try await session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 2,
            expectedMutationGeneration: session.mutationGeneration
        ).snapshot.sequence == 2)

        session.reset()
        #expect(try await session.record(
            snapshot(),
            simulatorID: "SIM-2",
            capturedAtMilliseconds: 3,
            expectedMutationGeneration: session.mutationGeneration
        ).snapshot.sequence == 3)
    }

    @Test("Snapshot invalidation advances the mutation generation")
    func mutationGenerationTracksExternalInput() {
        let session = SimulatorUIAutomationSession()
        let generation = session.mutationGeneration

        session.clearSnapshot()

        #expect(session.mutationGeneration == generation + 1)
    }

    @Test("Recording rejects a snapshot captured before the current generation")
    func recordingRejectsEarlierMutationGeneration() async {
        let session = SimulatorUIAutomationSession()
        let capturedGeneration = session.mutationGeneration
        session.clearSnapshot()

        await #expect(throws:
            SimulatorUIAutomationSnapshotRecordingError.invalidatedDuringPreparation
        ) {
            try await session.record(
                snapshot(),
                simulatorID: "SIM-1",
                capturedAtMilliseconds: 1_000,
                expectedMutationGeneration: capturedGeneration
            )
        }
    }

    @Test("A held semantic touch survives snapshot replacement until release")
    func heldTouchSurvivesSnapshotReplacement() {
        let session = SimulatorUIAutomationSession()
        let point = SimulatorPoint(x: 0.4, y: 0.6)
        let display = SimulatorDisplayMetadata(
            width: 1_170,
            height: 2_532,
            orientation: .portrait,
            scale: 3
        )

        session.holdTouch(elementRef: "e1_2", point: point, display: display)
        session.clearSnapshot()

        #expect(session.heldTouch(elementRef: "e1_2")?.point == point)
        #expect(session.heldTouch(elementRef: "e1_2")?.display == display)
        session.releaseHeldTouch(elementRef: "e1_2")
        #expect(session.heldTouch(elementRef: "e1_2") == nil)
    }

    @Test("Cancellation after queue acquisition cannot run the transaction")
    func cancelledQueuedTransactionDoesNotRun() async throws {
        let session = SimulatorUIAutomationSession()
        try await session.beginTransaction()
        var queuedStarted = false
        var operationRan = false
        let queued = Task { @MainActor in
            queuedStarted = true
            return try await session.withTransaction {
                operationRan = true
                return true
            }
        }
        while !queuedStarted {
            await Task.yield()
        }

        queued.cancel()
        session.endTransaction()

        await #expect(throws: CancellationError.self) {
            try await queued.value
        }
        #expect(!operationRan)
        #expect(try await session.withTransaction { true })
    }

    @Test("Cancellation while quiescing cannot run the transaction operation")
    func cancellationAfterQuiescingStartsDoesNotRun() async throws {
        let session = SimulatorUIAutomationSession()
        var quiescingStarted = false
        var finishQuiescing = false
        var operationRan = false
        let transaction = Task { @MainActor in
            try await session.withTransaction(beforeOperation: {
                quiescingStarted = true
                while !finishQuiescing {
                    await Task.yield()
                }
            }) {
                operationRan = true
            }
        }
        while !quiescingStarted {
            await Task.yield()
        }

        transaction.cancel()
        finishQuiescing = true

        await #expect(throws: CancellationError.self) {
            try await transaction.value
        }
        #expect(!operationRan)
        #expect(try await session.withTransaction { true })
    }

    @Test("An active transaction admits at most eight queued operations")
    func transactionQueueIsBounded() async throws {
        let session = SimulatorUIAutomationSession()
        try await session.beginTransaction()
        var queuedTasks: [Task<Void, any Error>] = []
        for _ in 0..<8 {
            queuedTasks.append(Task { @MainActor in
                try await session.beginTransaction()
                session.endTransaction()
            })
            await Task.yield()
        }

        let overflow = Task { @MainActor in
            do {
                try await session.beginTransaction()
                session.endTransaction()
                return false
            } catch is CancellationError {
                return false
            } catch {
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        overflow.cancel()
        let wasRejected = await overflow.value

        for task in queuedTasks { task.cancel() }
        session.endTransaction()
        for task in queuedTasks { _ = try? await task.value }

        #expect(wasRejected)
    }

    private func snapshot() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    isEnabled: true,
                    children: [
                        SimulatorAccessibilityNode(
                            id: "0.0",
                            identifier: "continue",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44),
                            isEnabled: true,
                            children: []
                        ),
                    ]
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }

    private func snapshotWithDuplicateIdentifiers() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    isEnabled: true,
                    children: [
                        SimulatorAccessibilityNode(
                            id: "0.0",
                            identifier: "duplicate",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44),
                            isEnabled: true,
                            children: []
                        ),
                        SimulatorAccessibilityNode(
                            id: "0.1",
                            identifier: "duplicate",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            frame: SimulatorRect(x: 20, y: 160, width: 120, height: 44),
                            isEnabled: true,
                            children: []
                        ),
                    ]
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }

    private func snapshotWithoutIdentifiers() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    isEnabled: true,
                    children: [
                        SimulatorAccessibilityNode(
                            id: "0.0",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44),
                            isEnabled: true,
                            children: []
                        ),
                    ]
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }
}
