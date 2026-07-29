import Foundation
import Testing
import CmuxSettings
@testable import CmuxControlSocket

@MainActor
private final class FakeNotificationPresentationContext: ControlCommandContext {
    let workspaceID = UUID()
    let surfaceID = UUID()
    var capturedPresentation: ControlNotificationPresentation?
    var createCallCount = 0
    var existingNotifications: [ControlNotificationSnapshot] = []
    var dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
        enabled: false,
        horizontalPosition: 0.5
    )
    var configuredDynamicNotchEnabled: Bool?
    var configuredDynamicNotchPosition: Double?
    var configuredDynamicNotchDisplayKey: String?
    var configuredDynamicNotchReset = false

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

    func controlNotificationList() -> [ControlNotificationSnapshot] {
        existingNotifications
    }

    func controlDynamicNotchSettings()
        -> ControlDynamicNotchSettingsSnapshot {
        dynamicNotchSettings
    }

    func controlDynamicNotchConfigure(
        enabled: Bool?,
        horizontalPosition: Double?,
        displayKey: String?,
        resetDisplayPosition: Bool
    ) -> ControlDynamicNotchSettingsSnapshot {
        configuredDynamicNotchEnabled = enabled
        configuredDynamicNotchPosition = horizontalPosition
        configuredDynamicNotchDisplayKey = displayKey
        configuredDynamicNotchReset = resetDisplayPosition
        dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
            enabled: enabled ?? dynamicNotchSettings.enabled,
            horizontalPosition:
                displayKey == nil
                    ? horizontalPosition
                        ?? dynamicNotchSettings.horizontalPosition
                    : dynamicNotchSettings.horizontalPosition,
            displays: dynamicNotchSettings.displays
        )
        return dynamicNotchSettings
    }
}

@MainActor
@Suite("ControlCommandCoordinator notification presentation")
struct ControlCommandCoordinatorNotificationPresentationTests {
    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "notification.create", params: params)
    }

    @Test func defaultPresentationPreservesLegacyNotificationBehavior() {
        let presentation = ControlNotificationPresentation()

        #expect(presentation.delivery == .settings)
        #expect(presentation.iconSymbolName == nil)
        #expect(presentation.actions.isEmpty)
        #expect(presentation.inputs.isEmpty)
        #expect(presentation.responseToken == nil)
        #expect(presentation.timeout == 8)
    }

    @Test func dynamicFormCrossesTheControlSeamWithoutLosingCallerData() throws {
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
            "appearance": .object([
                "expandedWidth": .int(620),
                "accentColor": .string("#0A84FF"),
                "showScrollIndicators": .bool(false),
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
            appearance: try DynamicNotchAppearanceOverrides(jsonObject: [
                "expandedWidth": 620,
                "accentColor": "#0A84FF",
                "showScrollIndicators": false,
            ]),
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

    @Test func callerSuppliedActiveNotificationIDIsRejected() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let notificationID = UUID()
        context.existingNotifications = [
            ControlNotificationSnapshot(
                id: notificationID,
                workspaceID: UUID(),
                surfaceID: nil,
                title: "Existing",
                subtitle: "",
                body: "",
                createdAtISO8601: "2026-01-01T00:00:00Z",
                isRead: false,
                tabTitle: nil
            ),
        ]

        let result = coordinator.handle(request([
            "notification_id": .string(notificationID.uuidString),
            "title": .string("Duplicate"),
        ]))

        #expect(result == .err(
            code: "invalid_params",
            message: "invalid notification presentation",
            data: nil
        ))
        #expect(context.createCallCount == 0)
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
        [
            "delivery": JSONValue.string("system"),
            "appearance": .object(["expandedWidth": .int(620)]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "appearance": .object(["expandedWidth": .int(299)]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "appearance": .object(["unknown": .int(1)]),
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

    @Test func dynamicNotchSettingsAreReadableAndConfigurable() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let initial = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "notification.dynamic_notch.settings",
                params: [:]
            )
        )
        #expect(initial == .ok(.object([
            "enabled": .bool(false),
            "delivery": .string("system"),
            "horizontal_position": .double(0.5),
            "displays": .array([]),
        ])))

        let configured = coordinator.handle(
            ControlRequest(
                id: .int(2),
                method: "notification.dynamic_notch.configure",
                params: [
                    "enabled": .bool(true),
                    "horizontal_position": .double(0.25),
                ]
            )
        )
        #expect(context.configuredDynamicNotchEnabled == true)
        #expect(context.configuredDynamicNotchPosition == 0.25)
        #expect(configured == .ok(.object([
            "enabled": .bool(true),
            "delivery": .string("dynamicNotch"),
            "horizontal_position": .double(0.25),
            "displays": .array([]),
        ])))
    }

    @Test func dynamicNotchPositionCanTargetOneDisplay() {
        let context = FakeNotificationPresentationContext()
        context.dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
            enabled: true,
            horizontalPosition: 0.5,
            displays: [
                ControlDynamicNotchDisplaySnapshot(
                    key: "uuid:external",
                    id: 42,
                    name: "Studio Display",
                    hasHardwareNotch: false,
                    horizontalPosition: 0.7,
                    hasPositionOverride: true
                ),
            ]
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(3),
                method: "notification.dynamic_notch.configure",
                params: [
                    "horizontal_position": .double(0.3),
                    "display_key": .string("uuid:external"),
                ]
            )
        )

        #expect(context.configuredDynamicNotchPosition == 0.3)
        #expect(
            context.configuredDynamicNotchDisplayKey == "uuid:external"
        )
        #expect(!context.configuredDynamicNotchReset)
        guard case .ok(.object(let payload)) = result,
              case .array(let displays) = payload["displays"] else {
            Issue.record("Expected a display settings payload")
            return
        }
        #expect(displays.count == 1)
    }

    @Test(arguments: [
        ["enabled": JSONValue.string("yes")],
        ["horizontal_position": JSONValue.bool(true)],
        ["horizontal_position": JSONValue.double(-0.01)],
        ["horizontal_position": JSONValue.double(1.01)],
        ["display_key": JSONValue.string("uuid:external")],
        [
            "display_key": JSONValue.string("uuid:external"),
            "reset_display_position": JSONValue.bool(true),
            "horizontal_position": JSONValue.double(0.5),
        ],
        ["reset_display_position": JSONValue.bool(true)],
        [:],
    ])
    func invalidDynamicNotchConfigurationIsRejected(
        params: [String: JSONValue]
    ) {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "notification.dynamic_notch.configure",
                params: params
            )
        )

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.configuredDynamicNotchEnabled == nil)
        #expect(context.configuredDynamicNotchPosition == nil)
        #expect(context.configuredDynamicNotchDisplayKey == nil)
        #expect(!context.configuredDynamicNotchReset)
    }
}
