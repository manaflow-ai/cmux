import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
final class FakeSimulatorControlCommandContext: ControlCommandContext {
    var typeResolution: ControlSimulatorTypeStartResolution = .failed(.tabManagerUnavailable)
    var webResolution: ControlSimulatorWebInspectorStartResolution = .failed(.tabManagerUnavailable)
    var operationResolution: ControlSimulatorOperationStartResolution = .failed(.tabManagerUnavailable)
    var lastText: String?
    var lastTargetID: String?
    var lastJSON: String?
    var lastHighlight: Bool?
    var lastOperation: ControlSimulatorOperation?

    func controlSimulatorBeginType(
        routing: ControlRoutingSelectors,
        text: String
    ) -> ControlSimulatorTypeStartResolution {
        lastText = text
        return typeResolution
    }

    func controlSimulatorBeginWebInspectorTargets(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution { webResolution }

    func controlSimulatorBeginWebInspectorAttach(
        routing: ControlRoutingSelectors,
        targetID: String
    ) -> ControlSimulatorWebInspectorStartResolution {
        lastTargetID = targetID
        return webResolution
    }

    func controlSimulatorBeginWebInspectorSend(
        routing: ControlRoutingSelectors,
        json: String
    ) -> ControlSimulatorWebInspectorStartResolution {
        lastJSON = json
        return webResolution
    }

    func controlSimulatorBeginWebInspectorHighlight(
        routing: ControlRoutingSelectors,
        enabled: Bool
    ) -> ControlSimulatorWebInspectorStartResolution {
        lastHighlight = enabled
        return webResolution
    }

    func controlSimulatorBeginWebInspectorRelease(
        routing: ControlRoutingSelectors
    ) -> ControlSimulatorWebInspectorStartResolution { webResolution }

    func controlSimulatorBeginOperation(
        routing: ControlRoutingSelectors,
        operation: ControlSimulatorOperation
    ) -> ControlSimulatorOperationStartResolution {
        lastOperation = operation
        return operationResolution
    }
}

private final class SimulatorTypeCallHarness: @unchecked Sendable {
    let coordinator: ControlCommandCoordinator
    let context: FakeSimulatorControlCommandContext
    let params: [String: JSONValue]

    @MainActor
    init(
        coordinator: ControlCommandCoordinator,
        context: FakeSimulatorControlCommandContext,
        params: [String: JSONValue]
    ) {
        self.coordinator = coordinator
        self.context = context
        self.params = params
    }

    func call(timeout: TimeInterval?) -> ControlCallResult {
        coordinator.simulatorType(params, context: context, completionTimeout: timeout)
    }
}

private final class SimulatorResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ControlCallResult?

    func set(_ value: ControlCallResult) { lock.withLock { self.value = value } }
    func get() -> ControlCallResult? { lock.withLock { value } }
}

@MainActor
@Suite("ControlCommandCoordinator Simulator domain")
struct ControlCommandCoordinatorSimulatorTests {
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

        for json in ["[]", "{", String(repeating: "x", count: 1_048_577)] {
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

    @Test("serve-sim hardware button aliases map to native button names")
    func buttonAliases() {
        let aliases = [
            "swipe_home": "swipeHome",
            "app_switcher": "appSwitcher",
            "side_button": "sideButton",
            "volume_up": "volumeUp",
            "volume_down": "volumeDown",
            "watch_side_button": "watchSideButton",
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

    @Test("Accessibility and foreground reads use correlated Simulator operations")
    func accessibilityAndForegroundOperations() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["node_count": .int(75)])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        guard case let .ok(.object(accessibility)) = coordinator.handleSocketWorkerV2(
            request("simulator.accessibility"), context: context
        ) else {
            Issue.record("Expected accessibility payload")
            return
        }
        #expect(context.lastOperation == .accessibility)
        #expect(accessibility["node_count"] == .int(75))

        let foregroundReceipt = ControlSimulatorOperationReceipt()
        foregroundReceipt.complete(.success(.object([
            "application": .object(["bundle_id": .string("com.example.App")]),
        ])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: foregroundReceipt
        )
        _ = coordinator.handleSocketWorkerV2(
            request("simulator.foreground"), context: context
        )
        #expect(context.lastOperation == .foregroundApplication)
    }

    @Test("Permission and interface methods stay on the bounded socket worker")
    func settingsExecutionPolicy() {
        for method in [
            "simulator.permissions.read", "simulator.permissions.set",
            "simulator.ui.status", "simulator.ui.set",
        ] {
            #expect(
                ControlCommandExecutionPolicy(forMethod: method)
                    == .socketWorker(mainThreadCallable: false),
                "\(method)"
            )
        }
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
