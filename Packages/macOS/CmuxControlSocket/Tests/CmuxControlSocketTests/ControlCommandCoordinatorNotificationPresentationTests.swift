import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeNotificationPresentationContext: ControlCommandContext {
    let workspaceID = UUID()
    let surfaceID = UUID()
    var capturedPresentation: ControlNotificationPresentation?
    var createCallCount = 0

    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String,
        presentation: ControlNotificationPresentation
    ) -> ControlNotificationCreateResolution {
        createCallCount += 1
        capturedPresentation = presentation
        return .delivered(workspaceID: workspaceID, surfaceID: surfaceID)
    }
}

@MainActor
@Suite("ControlCommandCoordinator notification presentation")
struct ControlCommandCoordinatorNotificationPresentationTests {
    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "notification.create", params: params)
    }

    @Test func dynamicFormCrossesTheControlSeamWithoutLosingCallerData() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let notificationID = UUID()
        let responseToken = UUID()

        let result = coordinator.handle(request([
            "notification_id": .string(notificationID.uuidString),
            "delivery": .string("dynamicNotch"),
            "icon": .string("hand.raised.fill"),
            "actions": .array([
                .object(["id": .string("approve"), "title": .string("Approve")]),
                .object(["id": .string("deny"), "title": .string("Deny")]),
            ]),
            "inputs": .array([
                .object([
                    "id": .string("reason"),
                    "label": .string("Reason"),
                    "placeholder": .string("Optional note"),
                    "initial_value": .string("Looks good"),
                    "secure": .bool(false),
                ]),
                .object([
                    "id": .string("token"),
                    "label": .string("Token"),
                    "secure": .bool(true),
                ]),
            ]),
            "response_token": .string(responseToken.uuidString),
            "timeout": .double(120),
        ]))

        #expect(result == .ok(.object([
            "id": .string(notificationID.uuidString),
            "workspace_id": .string(context.workspaceID.uuidString),
            "surface_id": .string(context.surfaceID.uuidString),
        ])))
        #expect(context.capturedPresentation == ControlNotificationPresentation(
            notificationID: notificationID,
            delivery: .dynamicNotch,
            iconSymbolName: "hand.raised.fill",
            actions: [
                .init(id: "approve", title: "Approve"),
                .init(id: "deny", title: "Deny"),
            ],
            inputs: [
                .init(
                    id: "reason",
                    label: "Reason",
                    placeholder: "Optional note",
                    initialValue: "Looks good",
                    kind: .text
                ),
                .init(
                    id: "token",
                    label: "Token",
                    placeholder: "",
                    initialValue: "",
                    kind: .secure
                ),
            ],
            responseToken: responseToken,
            timeout: 120
        ))
    }

    @Test func ordinaryCreateKeepsSettingsDeliveryAndGeneratesAnIdentifier() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(["title": .string("Done")]))

        guard let presentation = context.capturedPresentation else {
            Issue.record("notification.create did not reach the context")
            return
        }
        #expect(presentation.delivery == .settings)
        #expect(presentation.actions.isEmpty)
        #expect(presentation.inputs.isEmpty)
        #expect(presentation.timeout == 8)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("notification.create returned an error")
            return
        }
        #expect(payload["id"] == .string(presentation.notificationID.uuidString))
    }

    @Test(arguments: [
        [
            "delivery": JSONValue.string("system"),
            "actions": .array([
                .object(["id": .string("approve"), "title": .string("Approve")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "actions": .array([
                .object(["id": .string("open"), "title": .string("Override built-in")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "inputs": .array([
                .object([
                    "id": .string("reason"),
                    "label": .string("Reason"),
                    "secure": .string("yes"),
                ]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "inputs": .array([
                .object(["id": .string("../reason"), "label": .string("Reason")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "actions": .array([
                .object(["id": .string("承認"), "title": .string("Approve")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "actions": .array([
                .object([
                    "id": .string("approve"),
                    "title": .string("Approve"),
                    "command": .string("deploy"),
                ]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "timeout": .bool(true),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "inputs": .array([
                .object([
                    "id": .string("reason"),
                    "label": .string("Reason"),
                    "placeholder": .int(42),
                ]),
            ]),
        ],
    ])
    func malformedOrUnsafeFormsAreRejectedBeforeAppMutation(
        params: [String: JSONValue]
    ) {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(params))

        #expect(result == .err(
            code: "invalid_params",
            message: "invalid notification presentation",
            data: nil
        ))
        #expect(context.createCallCount == 0)
    }
}
