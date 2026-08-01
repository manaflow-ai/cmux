import CmuxControlSocket
import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI
@testable import CmuxSimulatorUIAutomation

@MainActor
@Suite("Simulator UI automation executor waits")
struct SimulatorUIAutomationExecutorWaitTests {
    @Test("Cancellation after a committed tap returns success with a warning")
    func cancellationAfterCommittedTapReturnsSuccess() async throws {
        let snapshot = Self.actionSnapshot()
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot),
            cancelsControlActionBeforeReturning: true
        )
        let coordinator = Self.actionCoordinator(client: client, snapshot: snapshot)
        let capturedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let record = try await coordinator.recordUIAutomationSnapshot(
            snapshot,
            simulatorID: "SIM-1",
            capturedAtMilliseconds: capturedAtMilliseconds,
            expectedMutationGeneration: coordinator.uiAutomationMutationGeneration
        )
        let elementRef = try #require(record.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)

        let operation = Task { @MainActor in
            try await SimulatorUIAutomationExecutor().perform(
                .uiAction(.tap(
                    elementRef: elementRef,
                    preDelayMilliseconds: 0,
                    postDelayMilliseconds: 0
                )),
                coordinator: coordinator
            )
        }
        let result = await operation.result

        switch result {
        case let .success(.object(payload)):
            #expect(payload["completed"] == .bool(true))
            #expect(payload["snapshot_warning"] != nil)
        case let .success(value):
            Issue.record("Expected an object result, got \(value)")
        case let .failure(error):
            Issue.record("Expected committed success, got \(error)")
        }
        await coordinator.close()
    }

    @Test("Ambiguous text fields are rejected before focus changes")
    func ambiguousTextFieldDoesNotTap() async throws {
        let snapshot = Self.ambiguousTextFieldSnapshot()
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = Self.actionCoordinator(client: client, snapshot: snapshot)
        let record = try await coordinator.recordUIAutomationSnapshot(
            snapshot,
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: coordinator.uiAutomationMutationGeneration
        )
        let elementRef = try #require(record.snapshot.elements.first {
            $0.role == .textField
        }?.ref)

        do {
            _ = try await SimulatorUIAutomationExecutor(
                scheduler: AdvancingActionScheduler(nowMilliseconds: 1_000)
            ).perform(
                .uiAction(.typeText(
                    elementRef: elementRef,
                    text: "Hello",
                    replaceExisting: false
                )),
                coordinator: coordinator
            )
            Issue.record("Expected the ambiguous text field to be rejected")
        } catch {}

        #expect(!(await client.actions().contains { action in
            if case .interactive = action { return true }
            return false
        }))
        await coordinator.close()
    }

    @Test("Up-only touch rejects a different held-touch ref")
    func mismatchedTouchUpPreservesHeldTouch() async throws {
        let snapshot = Self.twoButtonSnapshot()
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = Self.actionCoordinator(client: client, snapshot: snapshot)
        let record = try await coordinator.recordUIAutomationSnapshot(
            snapshot,
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: coordinator.uiAutomationMutationGeneration
        )
        let refs = record.snapshot.elements.filter { $0.role == .button }.map(\.ref)
        let heldRef = try #require(refs.first)
        let mismatchedRef = try #require(refs.dropFirst().first)
        let heldRecord = try #require(record.element(ref: heldRef))
        coordinator.holdUIAutomationTouch(
            elementRef: heldRef,
            point: heldRecord.activationPoint,
            display: record.display
        )

        do {
            _ = try await SimulatorUIAutomationExecutor(
                scheduler: AdvancingActionScheduler(nowMilliseconds: 1_000)
            ).perform(
                .uiAction(.touch(
                    elementRef: mismatchedRef,
                    down: false,
                    up: true,
                    delayMilliseconds: 0
                )),
                coordinator: coordinator
            )
            Issue.record("Expected mismatched touch-up to be rejected")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "touch_already_held")
        } catch {
            Issue.record("Expected a structured UI failure, got \(error)")
        }

        #expect(coordinator.heldUIAutomationTouch(elementRef: heldRef) != nil)
        #expect(!(await client.actions().contains { action in
            if case .interactive = action { return true }
            return false
        }))
        await coordinator.close()
    }

    @Test("A retained touch rejects a semantic tap before worker input")
    func retainedTouchRejectsSemanticTap() async throws {
        let snapshot = Self.actionSnapshot()
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = Self.actionCoordinator(client: client, snapshot: snapshot)
        let record = try await coordinator.recordUIAutomationSnapshot(
            snapshot,
            simulatorID: "SIM-1",
            capturedAtMilliseconds: 1_000,
            expectedMutationGeneration: coordinator.uiAutomationMutationGeneration
        )
        let elementRef = try #require(record.snapshot.elements.first {
            $0.identifier == "continue"
        }?.ref)
        coordinator.holdUIAutomationTouch(
            elementRef: elementRef,
            point: SimulatorPoint(x: 0.5, y: 0.5),
            display: record.display
        )

        do {
            _ = try await SimulatorUIAutomationExecutor(
                scheduler: AdvancingActionScheduler(nowMilliseconds: 1_000)
            ).perform(
                .uiAction(.tap(
                    elementRef: elementRef,
                    preDelayMilliseconds: 0,
                    postDelayMilliseconds: 0
                )),
                coordinator: coordinator
            )
            Issue.record("Expected a retained-touch failure")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "touch_already_held")
        } catch {
            Issue.record("Expected a structured UI failure, got \(error)")
        }

        #expect(coordinator.hasHeldUIAutomationTouch)
        #expect(!(await client.actions().contains { action in
            if case .interactive = action { return true }
            return false
        }))
        await coordinator.close()
    }

    @Test("Accessibility taps fail closed on truncated snapshots")
    func truncatedAccessibilityTapDoesNotSendInput() async {
        let snapshot = Self.truncated(Self.actionSnapshot())
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = Self.actionCoordinator(client: client, snapshot: snapshot)

        do {
            _ = try await SimulatorUIAutomationExecutor(
                scheduler: AdvancingActionScheduler(nowMilliseconds: 1_000)
            ).perform(
                .accessibilityTap(
                    label: "Continue",
                    identifier: nil,
                    role: nil
                ),
                coordinator: coordinator
            )
            Issue.record("Expected the truncated snapshot to be rejected")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "snapshot_truncated")
        } catch {
            Issue.record("Expected a structured UI failure, got \(error)")
        }

        #expect(!(await client.actions().contains { action in
            if case .interactive = action { return true }
            return false
        }))
        await coordinator.close()
    }

    @Test("Selector waits fail closed on truncated snapshots")
    func truncatedSelectorWaitIsRejected() async {
        let snapshot = Self.truncated(Self.actionSnapshot())
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = Self.actionCoordinator(client: client, snapshot: snapshot)
        let wait = ControlSimulatorUIWait(
            predicate: "exists",
            elementRef: nil,
            identifier: nil,
            label: "Continue",
            role: nil,
            value: nil,
            text: nil,
            timeoutMilliseconds: 0,
            pollIntervalMilliseconds: 100,
            settledDurationMilliseconds: 0
        )

        do {
            _ = try await SimulatorUIAutomationExecutor().perform(
                .uiWait(wait),
                coordinator: coordinator
            )
            Issue.record("Expected the truncated snapshot to be rejected")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "snapshot_truncated")
        } catch {
            Issue.record("Expected snapshot_truncated, got \(error)")
        }
        await coordinator.close()
    }

    @Test("Text-only gone waits reject heterogeneous matches")
    func textOnlyGoneRejectsAmbiguousMatches() async {
        let display = SimulatorDisplayMetadata(
            width: 1_170,
            height: 2_532,
            orientation: .portrait,
            scale: 3
        )
        let snapshot = SimulatorAccessibilitySnapshot(
            roots: [SimulatorAccessibilityNode(
                id: "root",
                role: "Application",
                label: "Example",
                value: nil,
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                isEnabled: true,
                children: [
                    SimulatorAccessibilityNode(
                        id: "pending",
                        role: "StaticText",
                        label: "Status pending",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 100, width: 160, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                    SimulatorAccessibilityNode(
                        id: "complete",
                        role: "StaticText",
                        label: "Status complete",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 160, width: 160, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                ]
            )],
            display: display
        )
        let client = SimulatorPaneClientSpy(
            devices: [],
            accessibilityResult: .accessibility(snapshot)
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.selectedDeviceID = "SIM-1"
        coordinator.capabilities = [.accessibility]
        coordinator.display = display
        let wait = ControlSimulatorUIWait(
            predicate: "gone",
            elementRef: nil,
            identifier: nil,
            label: nil,
            role: nil,
            value: nil,
            text: "Status",
            timeoutMilliseconds: 0,
            pollIntervalMilliseconds: 100,
            settledDurationMilliseconds: 0
        )

        do {
            _ = try await SimulatorUIAutomationExecutor().perform(
                .uiWait(wait),
                coordinator: coordinator
            )
            Issue.record("Expected an ambiguous wait failure")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "target_ambiguous")
        } catch {
            Issue.record("Expected target_ambiguous, got \(error)")
        }
        await coordinator.close()
    }

    private static func actionCoordinator(
        client: SimulatorPaneClientSpy,
        snapshot: SimulatorAccessibilitySnapshot
    ) -> SimulatorPaneCoordinator {
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.selectedDeviceID = "SIM-1"
        coordinator.capabilities = [.accessibility, .touch, .keyboard]
        coordinator.display = snapshot.display
        return coordinator
    }

    private static func actionSnapshot() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [SimulatorAccessibilityNode(
                id: "root",
                role: "Application",
                label: "Example",
                value: nil,
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                isEnabled: true,
                children: [SimulatorAccessibilityNode(
                    id: "continue",
                    identifier: "continue",
                    role: "AXButton",
                    label: "Continue",
                    value: nil,
                    frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44),
                    isEnabled: true,
                    children: []
                )]
            )],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }

    private static func truncated(
        _ snapshot: SimulatorAccessibilitySnapshot
    ) -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: snapshot.roots,
            display: snapshot.display,
            nodeCount: snapshot.nodeCount,
            isTruncated: true
        )
    }

    private static func ambiguousTextFieldSnapshot() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [SimulatorAccessibilityNode(
                id: "root",
                role: "Application",
                label: "Example",
                value: nil,
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                isEnabled: true,
                children: [
                    SimulatorAccessibilityNode(
                        id: "first",
                        role: "AXTextField",
                        label: "Name",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 100, width: 200, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                    SimulatorAccessibilityNode(
                        id: "second",
                        role: "AXTextField",
                        label: "Name",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 160, width: 200, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                ]
            )],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }

    private static func twoButtonSnapshot() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [SimulatorAccessibilityNode(
                id: "root",
                role: "Application",
                label: "Example",
                value: nil,
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                isEnabled: true,
                children: [
                    SimulatorAccessibilityNode(
                        id: "first",
                        identifier: "first",
                        role: "AXButton",
                        label: "First",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                    SimulatorAccessibilityNode(
                        id: "second",
                        identifier: "second",
                        role: "AXButton",
                        label: "Second",
                        value: nil,
                        frame: SimulatorRect(x: 20, y: 160, width: 120, height: 44),
                        isEnabled: true,
                        children: []
                    ),
                ]
            )],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }
}

private final class AdvancingActionScheduler:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var nowMilliseconds: Int64

    init(nowMilliseconds: Int64) {
        self.nowMilliseconds = nowMilliseconds
    }

    func monotonicNowMilliseconds() -> Int64 {
        lock.withLock { nowMilliseconds }
    }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock { nowMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        lock.withLock { nowMilliseconds += milliseconds }
    }
}
