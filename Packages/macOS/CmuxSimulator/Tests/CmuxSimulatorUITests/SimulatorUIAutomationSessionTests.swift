import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator UI automation session")
struct SimulatorUIAutomationSessionTests {
    @Test("Refs resolve only from the current unexpired snapshot")
    func refLifetime() throws {
        let session = SimulatorUIAutomationSession()
        let record = try session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000
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
    func actionContractAndInvalidation() throws {
        let session = SimulatorUIAutomationSession()
        let record = try session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000
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
    func replacementSnapshotInvalidatesOldRef() throws {
        let session = SimulatorUIAutomationSession()
        let first = try session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000
        )
        let oldRef = try #require(first.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)
        let second = try session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 2_000
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

    @Test("Recording and device reset preserve a monotonic sequence")
    func sequenceRemainsMonotonicAcrossReset() throws {
        let session = SimulatorUIAutomationSession()
        #expect(try session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1
        ).snapshot.sequence == 1)
        #expect(try session.record(
            snapshot(),
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 2
        ).snapshot.sequence == 2)

        session.reset()
        #expect(try session.record(
            snapshot(),
            simulatorID: "SIM-2",
            capturedAtMilliseconds: 3
        ).snapshot.sequence == 3)
    }

    @Test("Snapshot invalidation advances the mutation generation")
    func mutationGenerationTracksExternalInput() {
        let session = SimulatorUIAutomationSession()
        let generation = session.mutationGeneration

        session.clearSnapshot()

        #expect(session.mutationGeneration == generation + 1)
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
}
