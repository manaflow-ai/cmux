import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator Simulator UI automation")
struct ControlCommandCoordinatorSimulatorUIAutomationTests {
    @Test("Snapshot and wait parameters route as typed operations")
    func snapshotAndWaitRouting() throws {
        #expect(try operation(
            "simulator.snapshot_ui",
            ["since_screen_hash": .string("abc123")]
        ) == .uiSnapshot(sinceScreenHash: "abc123"))

        #expect(try operation("simulator.wait_for_ui", [
            "predicate": .string("focused"),
            "element_ref": .string("e1_12"),
            "timeout_milliseconds": .int(8_000),
            "poll_interval_milliseconds": .int(100),
            "settled_duration_milliseconds": .int(250),
        ]) == .uiWait(ControlSimulatorUIWait(
            predicate: "focused",
            elementRef: "e1_12",
            identifier: nil,
            label: nil,
            role: nil,
            value: nil,
            text: nil,
            timeoutMilliseconds: 8_000,
            pollIntervalMilliseconds: 100,
            settledDurationMilliseconds: 250
        )))

        #expect(try operation("simulator.wait_for_ui", [
            "predicate": .string("textContains"),
            "text": .string("General"),
        ]) == .uiWait(ControlSimulatorUIWait(
            predicate: "text-contains",
            elementRef: nil,
            identifier: nil,
            label: nil,
            role: nil,
            value: nil,
            text: "General",
            timeoutMilliseconds: 5_000,
            pollIntervalMilliseconds: 250,
            settledDurationMilliseconds: 500
        )))
    }

    @Test("Every ref-based action routes with bounded typed parameters")
    func semanticActionRouting() throws {
        #expect(try operation("simulator.tap", [
            "element_ref": .string("e1_2"),
            "pre_delay_milliseconds": .int(50),
            "post_delay_milliseconds": .int(75),
        ]) == .uiAction(.tap(
            elementRef: "e1_2",
            preDelayMilliseconds: 50,
            postDelayMilliseconds: 75
        )))

        #expect(try operation("simulator.touch", [
            "element_ref": .string("e1_3"),
            "down": .bool(true),
            "up": .bool(true),
            "delay_milliseconds": .int(300),
        ]) == .uiAction(.touch(
            elementRef: "e1_3",
            down: true,
            up: true,
            delayMilliseconds: 300
        )))

        #expect(try operation("simulator.swipe", [
            "within_element_ref": .string("e1_4"),
            "direction": .string("up"),
            "duration_milliseconds": .int(400),
            "distance": .double(0.8),
            "steps": .int(1_000),
        ]) == .uiAction(.swipe(
            elementRef: "e1_4",
            direction: "up",
            durationMilliseconds: 400,
            distance: 0.8,
            steps: 1_000,
            preDelayMilliseconds: 0,
            postDelayMilliseconds: 0
        )))

        #expect(try operation("simulator.drag", [
            "element_ref": .string("e1_5"),
            "direction": .string("right"),
            "steps": .int(1),
        ]) == .uiAction(.drag(
            elementRef: "e1_5",
            direction: "right",
            durationMilliseconds: 300,
            distance: 0.35,
            steps: 1,
            preDelayMilliseconds: 0,
            postDelayMilliseconds: 0
        )))

        #expect(try operation("simulator.long_press", [
            "element_ref": .string("e1_6"),
            "duration_milliseconds": .int(750),
        ]) == .uiAction(.longPress(
            elementRef: "e1_6",
            durationMilliseconds: 750
        )))

        #expect(try operation("simulator.type_text", [
            "element_ref": .string("e1_7"),
            "text": .string("hello"),
            "replace_existing": .bool(true),
        ]) == .uiAction(.typeText(
            elementRef: "e1_7",
            text: "hello",
            replaceExisting: true
        )))
    }

    @Test("Key, button, gesture, and batch actions route with structured values")
    func nonElementActionRouting() throws {
        #expect(try operation("simulator.key_press", [
            "key_code": .int(40),
            "duration_milliseconds": .int(80),
        ]) == .uiAction(.keyPress(
            keyCode: 40,
            durationMilliseconds: 80
        )))

        #expect(try operation("simulator.key_sequence", [
            "key_codes": .array([.int(40), .int(42)]),
            "delay_milliseconds": .int(25),
        ]) == .uiAction(.keySequence(
            keyCodes: [40, 42],
            delayMilliseconds: 25
        )))

        #expect(try operation("simulator.button", [
            "button": .string("apple-pay"),
            "duration_milliseconds": .int(100),
        ]) == .uiAction(.button(
            button: "applePay",
            durationMilliseconds: 100
        )))

        #expect(try operation("simulator.gesture_preset", [
            "preset": .string("swipe-from-left-edge"),
            "duration_milliseconds": .int(500),
            "distance": .double(0.7),
            "steps": .int(20),
        ]) == .uiAction(.gesturePreset(
            preset: "swipe-from-left-edge",
            durationMilliseconds: 500,
            distance: 0.7,
            steps: 20,
            preDelayMilliseconds: 0,
            postDelayMilliseconds: 0
        )))

        #expect(try operation("simulator.batch", [
            "steps": .array([
                .object([
                    "action": .string("tap"),
                    "element_ref": .string("e1_2"),
                ]),
                .object([
                    "action": .string("tap"),
                    "element_ref": .string("e1_3"),
                    "post_delay_milliseconds": .int(100),
                ]),
            ]),
        ]) == .uiAction(.batch(steps: [
            ControlSimulatorUITapStep(elementRef: "e1_2"),
            ControlSimulatorUITapStep(
                elementRef: "e1_3",
                postDelayMilliseconds: 100
            ),
        ])))
    }

    @Test("Invalid refs, empty text, zero gesture duration, and incomplete waits fail admission")
    func invalidParameters() {
        for (method, params) in [
            ("simulator.tap", ["element_ref": JSONValue.string("old-ref")]),
            ("simulator.tap", [
                "element_ref": .string("e1_1"),
                "x": .double(0.5),
                "y": .double(0.5),
            ]),
            ("simulator.tap", [
                "element_ref": .string("e1_1"),
                "label": .string("Continue"),
            ]),
            ("simulator.type_text", [
                "element_ref": .string("e1_1"),
                "text": .string(""),
                "replace_existing": .bool(false),
            ]),
            ("simulator.swipe", [
                "within_element_ref": .string("e1_1"),
                "direction": .string("up"),
                "duration_milliseconds": .int(0),
            ]),
            ("simulator.swipe", [
                "within_element_ref": .string("e1_1"),
                "direction": .string("up"),
                "from_x": .double(0.1),
                "from_y": .double(0.5),
                "to_x": .double(0.9),
                "to_y": .double(0.5),
            ]),
            ("simulator.wait_for_ui", [
                "predicate": .string("focused"),
            ]),
            ("simulator.wait_for_ui", [
                "predicate": .string("settled"),
                "poll_interval_milliseconds": .int(1),
            ]),
            ("simulator.button", [
                "button": .string("launch-missiles"),
            ]),
            ("simulator.button", [
                "button": .string(String(repeating: "h", count: 129)),
            ]),
        ] {
            let context = FakeSimulatorControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
                request(method, params),
                context: context
            ) else {
                Issue.record("Expected \(method) to reject invalid parameters")
                continue
            }
            #expect(code == "invalid_params")
            #expect(context.lastOperation == nil)
        }
    }

    @Test("Plans longer than the receipt budget fail admission")
    func oversizedActionPlans() {
        let keyCodes = Array(repeating: JSONValue.int(40), count: 100)
        let batchSteps = Array(
            repeating: JSONValue.object([
                "action": .string("tap"),
                "element_ref": .string("e1_1"),
                "pre_delay_milliseconds": .int(10_000),
                "post_delay_milliseconds": .int(10_000),
            ]),
            count: 100
        )
        for (method, params) in [
            ("simulator.key_sequence", [
                "key_codes": JSONValue.array(keyCodes),
                "delay_milliseconds": .int(5_000),
            ]),
            ("simulator.batch", [
                "steps": JSONValue.array(batchSteps),
            ]),
        ] {
            let context = FakeSimulatorControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
                request(method, params),
                context: context
            ) else {
                Issue.record("Expected \(method) to reject an oversized action plan")
                continue
            }
            #expect(code == "invalid_params")
            #expect(context.lastOperation == nil)
        }
    }

    @Test("Recoverable UI failure details survive the Simulator receipt hop")
    func structuredFailureData() throws {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.failed(
            code: "snapshot_expired",
            message: "expired",
            data: .object([
                "ui_error": .object([
                    "code": .string("SNAPSHOT_EXPIRED"),
                    "recovery_hint": .string("capture again"),
                    "snapshot_age_milliseconds": .int(61_000),
                ]),
            ])
        ))
        let surfaceID = UUID()
        context.operationResolution = .started(
            surfaceID: surfaceID,
            timeoutSeconds: 1,
            receipt: receipt
        )

        guard case let .err(code, _, .object(data)) = coordinator.handleSocketWorkerV2(
            request("simulator.snapshot_ui", [:]),
            context: context
        ) else {
            Issue.record("Expected a structured UI failure")
            return
        }
        #expect(code == "snapshot_expired")
        #expect(data["surface_id"] == .string(surfaceID.uuidString))
        let uiError = try #require(data["ui_error"])
        #expect(uiError == .object([
            "code": .string("SNAPSHOT_EXPIRED"),
            "recovery_hint": .string("capture again"),
            "snapshot_age_milliseconds": .int(61_000),
        ]))
    }

    private func operation(
        _ method: String,
        _ params: [String: JSONValue]
    ) throws -> ControlSimulatorOperation {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["completed": .bool(true)])))
        context.operationResolution = .started(
            surfaceID: UUID(),
            timeoutSeconds: 1,
            receipt: receipt
        )

        guard case .ok = coordinator.handleSocketWorkerV2(
            request(method, params),
            context: context
        ) else {
            Issue.record("Expected \(method) to route")
            throw ControlCommandCoordinatorSimulatorUIAutomationTestFailure()
        }
        return try #require(context.lastOperation)
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
