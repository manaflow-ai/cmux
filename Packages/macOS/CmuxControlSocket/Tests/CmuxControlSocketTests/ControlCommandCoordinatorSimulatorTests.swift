import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator Simulator domain")
struct ControlCommandCoordinatorSimulatorTests {
    @Test("Operation receipt cancels work when its deadline expires")
    func operationReceiptCancelsTimedOutWork() {
        let receipt = ControlSimulatorOperationReceipt(cancellationJoinTimeout: 0)
        let cancelled = SimulatorCancellationProbe()
        receipt.installCancellation { cancelled.mark() }

        #expect(receipt.wait(timeout: 0) == nil)
        #expect(cancelled.isMarked)
    }

    @Test("Text receipt cancels queued input when its deadline expires")
    func textReceiptCancelsTimedOutInput() {
        let receipt = ControlSimulatorCompletionReceipt(cancellationJoinTimeout: 0)
        let cancelled = SimulatorCancellationProbe()
        receipt.installCancellation { cancelled.mark() }

        #expect(receipt.wait(timeout: 0) == nil)
        #expect(cancelled.isMarked)
    }

    @Test("Web Inspector receipt cancels work when its deadline expires")
    func webInspectorReceiptCancelsTimedOutWork() {
        let receipt = ControlSimulatorWebInspectorReceipt(cancellationJoinTimeout: 0)
        let cancelled = SimulatorCancellationProbe()
        receipt.installCancellation { cancelled.mark() }

        #expect(receipt.wait(timeout: 0) == nil)
        #expect(cancelled.isMarked)
    }

    @Test("Operation receipt returns completion delivered while cancellation joins")
    func operationReceiptReturnsCancellationCompletion() {
        let receipt = ControlSimulatorOperationReceipt(cancellationJoinTimeout: 1)
        receipt.installCancellation {
            receipt.complete(.success(.object(["completed": .bool(true)])))
        }

        #expect(receipt.wait(timeout: 0) == .success(.object(["completed": .bool(true)])))
    }

    @Test("Text receipt returns completion delivered while cancellation joins")
    func textReceiptReturnsCancellationCompletion() {
        let receipt = ControlSimulatorCompletionReceipt(cancellationJoinTimeout: 1)
        receipt.installCancellation { receipt.complete(.succeeded) }

        #expect(receipt.wait(timeout: 0) == .succeeded)
    }

    @Test("Web Inspector receipt returns completion delivered while cancellation joins")
    func webInspectorReceiptReturnsCancellationCompletion() {
        let receipt = ControlSimulatorWebInspectorReceipt(cancellationJoinTimeout: 1)
        receipt.installCancellation { receipt.complete(.released) }

        #expect(receipt.wait(timeout: 0) == .released)
    }

    @Test("Long Simulator waits have bounded admission")
    func operationAdmissionIsBounded() {
        let gate = ControlSimulatorOperationAdmissionGate(maximumConcurrentOperations: 2)
        #expect(gate.acquire())
        #expect(gate.acquire())
        #expect(!gate.acquire())
        gate.release()
        #expect(gate.acquire())
        gate.release()
        gate.release()
    }

    @Test("Text success waits off-main for the correlated worker receipt")
    func textWaitsForReceipt() async {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorCompletionReceipt()
        let surfaceID = UUID()
        context.typeResolution = .started(
            surfaceID: surfaceID,
            characterCount: 3,
            completionTimeoutSeconds: 10,
            receipt: receipt
        )
        let harness = SimulatorTypeCallHarness(
            coordinator: coordinator,
            context: context,
            params: ["text": .string("abc")]
        )
        let box = SimulatorResultBox()
        let task = Task.detached {
            let result = harness.call(timeout: 1)
            box.set(result)
            return result
        }

        for _ in 0..<20 { await Task.yield() }
        #expect(box.get() == nil)
        // Reaching this main-actor line while the socket worker waits proves
        // the receipt does not block UI isolation.
        #expect(context.lastText == "abc")

        receipt.complete(.succeeded)
        let result = await task.value
        #expect(result == .ok(.object([
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "character_count": .int(3),
        ])))
    }

    @Test("Text timeout fails and a receipt resolves exactly once")
    func textTimeoutAndSingleResolution() async {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorCompletionReceipt()
        context.typeResolution = .started(
            surfaceID: UUID(),
            characterCount: 1,
            completionTimeoutSeconds: 10,
            receipt: receipt
        )
        let harness = SimulatorTypeCallHarness(
            coordinator: coordinator,
            context: context,
            params: ["text": .string("a")]
        )

        let result = await Task.detached { harness.call(timeout: 0.01) }.value
        guard case let .err(code, _, _) = result else {
            Issue.record("Expected timeout")
            return
        }
        #expect(code == "timeout")

        receipt.complete(.failed)
        receipt.complete(.succeeded)
        #expect(receipt.wait(timeout: 0) == .failed)
    }

    @Test("Targets return a cached native snapshot and start refresh")
    func inspectorTargetsSnapshot() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let surfaceID = UUID()
        let snapshot = ControlSimulatorWebInspectorSnapshot(
                surfaceID: surfaceID,
                targets: [ControlSimulatorWebInspectorTargetSnapshot(
                    id: "app:1",
                    applicationIdentifier: "PID:1",
                    pageIdentifier: 7,
                    title: "Fixture",
                    url: "https://example.com",
                    type: "WIRTypeWebPage",
                    applicationName: "Fixture App",
                    bundleIdentifier: "com.example.fixture",
                    isInUse: false
                )],
                session: .detached,
                isHighlighted: false
            )
        let receipt = ControlSimulatorWebInspectorReceipt()
        receipt.complete(.targets(snapshot))
        context.webResolution = .started(surfaceID: surfaceID, timeoutSeconds: 1, receipt: receipt)

        guard case let .ok(.object(payload)) = coordinator.handleSocketWorkerV2(
            request("simulator.web_inspector.targets"),
            context: context
        ) else {
            Issue.record("Expected target snapshot")
            return
        }
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
    }

    @Test("Inspector send rejects invalid or oversized JSON before routing")
    func inspectorSendValidation() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorWebInspectorReceipt()
        receipt.complete(.released)
        context.webResolution = .started(surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt)

        for json in ["[]", "{", #"{"id":null}"#, #"{"id":true}"#,
                     #"{"id":1.5}"#, #"{"id":9007199254740992}"#,
                     "{\"id\":\"\(String(repeating: "x", count: 1_025))\"}",
                     String(repeating: "x", count: 1_048_577)] {
            guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
                request("simulator.web_inspector.send", ["json": .string(json)]),
                context: context
            ) else {
                Issue.record("Expected invalid JSON error")
                continue
            }
            #expect(code == "invalid_params")
        }
        #expect(context.lastJSON == nil)
    }

    @Test("Inspector mutations expose async acceptance and routing errors")
    func inspectorMutationResults() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let surfaceID = UUID()
        let receipt = ControlSimulatorWebInspectorReceipt()
        receipt.complete(.session(.attached(sessionID: UUID(), targetID: "target-1")))
        context.webResolution = .started(surfaceID: surfaceID, timeoutSeconds: 1, receipt: receipt)

        guard case let .ok(.object(attachPayload)) = coordinator.handleSocketWorkerV2(
            request("simulator.web_inspector.attach", ["target_id": .string("target-1")]),
            context: context
        ) else {
            Issue.record("Expected correlated attach result")
            return
        }
        #expect(attachPayload["surface_id"] == .string(surfaceID.uuidString))
        #expect(context.lastTargetID == "target-1")

        context.webResolution = .failed(.remoteWorkspace)
        guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
            request("simulator.web_inspector.highlight", ["enabled": .bool(true)]),
            context: context
        ) else {
            Issue.record("Expected remote-workspace rejection")
            return
        }
        #expect(code == "unsupported")
    }

    @Test("Tap expands to one correlated ordered touch sequence")
    func tapSequence() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let surfaceID = UUID()
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["completed": .bool(true)])))
        context.operationResolution = .started(
            surfaceID: surfaceID, timeoutSeconds: 1, receipt: receipt
        )

        guard case let .ok(.object(payload)) = coordinator.handleSocketWorkerV2(
            request("simulator.tap", ["x": .double(0.25), "y": .double(0.75)]),
            context: context
        ) else {
            Issue.record("Expected correlated tap success")
            return
        }
        #expect(context.lastOperation == .gesture([
            ControlSimulatorTouch(phase: "began", x: 0.25, y: 0.75),
            ControlSimulatorTouch(phase: "ended", x: 0.25, y: 0.75),
        ]))
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["completed"] == .bool(true))
    }

    @Test("Recovery routes to a failed Simulator without worker parameters")
    func recoveryOperation() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["completed": .bool(true)])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        guard case let .ok(.object(payload)) = coordinator.handleSocketWorkerV2(
            request("simulator.recover"), context: context
        ) else {
            Issue.record("Expected correlated recovery acceptance")
            return
        }
        #expect(context.lastOperation == .recover)
        #expect(payload["completed"] == .bool(true))
        #expect(
            ControlCommandExecutionPolicy(forMethod: "simulator.recover")
                == .socketWorker(mainThreadCallable: false)
        )
    }

    @Test("Agent operations validate bounds and preserve routing failures")
    func operationValidationAndRouting() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        guard case let .err(invalidCode, _, _) = coordinator.handleSocketWorkerV2(
            request("simulator.swipe", [
                "from_x": .double(-1), "from_y": .double(0),
                "to_x": .double(1), "to_y": .double(1),
            ]),
            context: context
        ) else {
            Issue.record("Expected coordinate rejection")
            return
        }
        #expect(invalidCode == "invalid_params")
        #expect(context.lastOperation == nil)

        context.operationResolution = .failed(.remoteWorkspace)
        guard case let .err(remoteCode, _, _) = coordinator.handleSocketWorkerV2(
            request("simulator.memory_warning"), context: context
        ) else {
            Issue.record("Expected remote rejection")
            return
        }
        #expect(remoteCode == "unsupported")
    }

    @Test("Camera switch is source-only")
    func cameraSwitch() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([:])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        _ = coordinator.handleSocketWorkerV2(request("simulator.camera.switch", [
            "source": .string("video"), "path": .string("/tmp/fixture.mp4"),
        ]), context: context)
        #expect(context.lastOperation == .cameraSwitch(
            source: "video", path: "/tmp/fixture.mp4", loops: true,
            hostDeviceID: nil
        ))
    }

    @Test("serve-sim hardware button aliases and mixed-case native names map to canonical names")
    func buttonAliases() {
        let aliases = [
            "swipe_home": "swipeHome",
            "app_switcher": "appSwitcher",
            "side_button": "sideButton",
            "volume_up": "volumeUp",
            "volume_down": "volumeDown",
            "watch_side_button": "watchSideButton",
            "Home": "home",
            "SwipeHome": "swipeHome",
            "AppSwitcher": "appSwitcher",
            "SideButton": "sideButton",
            "VolumeUp": "volumeUp",
            "VolumeDown": "volumeDown",
            "WatchSideButton": "watchSideButton",
        ]
        for (alias, expected) in aliases {
            let context = FakeSimulatorControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let receipt = ControlSimulatorOperationReceipt()
            receipt.complete(.success(.object([:])))
            context.operationResolution = .started(
                surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
            )
            _ = coordinator.handleSocketWorkerV2(
                request("simulator.button", ["button": .string(alias)]), context: context
            )
            #expect(context.lastOperation == .hardwareButton(expected))
        }
    }

    @Test("Rotate accepts mixed-case hyphenated orientation aliases")
    func rotateAliases() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([:])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        for (alias, expected) in [
            "Landscape-Left": "landscape_left",
            "PORTRAIT-UPSIDE-DOWN": "portrait_upside_down",
        ] {
            _ = coordinator.handleSocketWorkerV2(request("simulator.rotate", [
                "orientation": .string(alias),
            ]), context: context)
            #expect(context.lastOperation == .rotate(expected))
        }
    }

    @Test("Gesture touch phases are case insensitive")
    func gesturePhaseNames() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([:])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        _ = coordinator.handleSocketWorkerV2(request("simulator.gesture", [
            "events": .array(["Began", "MOVED", "Ended"].map { phase in
                .object([
                    "phase": .string(phase), "x": .double(0.25), "y": .double(0.75),
                ])
            }),
        ]), context: context)

        #expect(context.lastOperation == .gesture(["began", "moved", "ended"].map { phase in
            ControlSimulatorTouch(phase: phase, x: 0.25, y: 0.75, edge: "none")
        }))
    }

    @Test("Core Animation diagnostic names are case insensitive")
    func coreAnimationDiagnosticNames() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([:])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        _ = coordinator.handleSocketWorkerV2(request("simulator.core_animation", [
            "diagnostic": .string("Blended"), "enabled": .bool(true),
        ]), context: context)
        #expect(context.lastOperation == .coreAnimation(diagnostic: "blended", enabled: true))
    }

    @Test("Permission methods route bounded canonical operations")
    func permissionOperations() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([
            "permissions": .object(["camera": .string("granted")]),
        ])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        _ = coordinator.handleSocketWorkerV2(request("simulator.permissions.read", [
            "bundle_id": .string("com.example.App"),
        ]), context: context)
        #expect(context.lastOperation == .permissionsRead(bundleIdentifier: "com.example.App"))

        _ = coordinator.handleSocketWorkerV2(request("simulator.permissions.set", [
            "action": .string("grant"),
            "service": .string("photos-limited"),
            "bundle_id": .string("com.example.App"),
        ]), context: context)
        #expect(context.lastOperation == .permissionsSet(
            action: "grant",
            service: "photos-limited",
            bundleIdentifier: "com.example.App"
        ))

        for bundleIdentifier in ["bad id", String(repeating: "a", count: 256)] {
            context.lastOperation = nil
            guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
                request("simulator.permissions.read", [
                    "bundle_id": .string(bundleIdentifier),
                ]),
                context: context
            ) else {
                Issue.record("Expected invalid bundle identifier rejection")
                continue
            }
            #expect(code == "invalid_params")
            #expect(context.lastOperation == nil)
        }
    }

    @Test("Interface methods route bounded canonical operations")
    func interfaceOperations() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([
            "settings": .object(["appearance": .string("dark")]),
        ])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        _ = coordinator.handleSocketWorkerV2(
            request("simulator.ui.status"),
            context: context
        )
        #expect(context.lastOperation == .interfaceStatus)

        _ = coordinator.handleSocketWorkerV2(request("simulator.ui.set", [
            "option": .string("color-filter"),
            "value": .string("red-green"),
        ]), context: context)
        #expect(context.lastOperation == .interfaceSet(
            option: "color-filter",
            value: "red-green"
        ))

        for invalidToken in [
            "", "Red Green", "é", String(repeating: "x", count: 65),
        ] {
            context.lastOperation = nil
            guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
                request("simulator.ui.set", [
                    "option": .string(invalidToken),
                    "value": .string("on"),
                ]),
                context: context
            ) else {
                Issue.record("Expected non-canonical interface token rejection")
                continue
            }
            #expect(code == "invalid_params")
            #expect(context.lastOperation == nil)
        }
    }

    @Test("Tools visibility routes only canonical actions")
    func toolsVisibility() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["visible": .bool(true)])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        for action in ["show", "hide", "toggle"] {
            _ = coordinator.handleSocketWorkerV2(request("simulator.tools", [
                "action": .string(action),
            ]), context: context)
            #expect(context.lastOperation == .tools(action))
        }

        context.lastOperation = nil
        guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
            request("simulator.tools", ["action": .string("open")]),
            context: context
        ) else {
            Issue.record("Expected invalid tools action rejection")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastOperation == nil)
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}

private final class SimulatorCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var isMarked: Bool {
        lock.withLock { marked }
    }

    func mark() {
        lock.withLock { marked = true }
    }
}
