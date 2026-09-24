import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class NotificationControlCommandContext: ControlCommandContext {
    let notificationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let workspaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private(set) var clearWorkspaceID: UUID?
    private(set) var clearSurfaceID: UUID?
    private(set) var clearCallerWorkspaceID: UUID?
    private(set) var clearCallerSurfaceID: UUID?

    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String,
        replyShapeWire: String?
    ) -> ControlNotificationCreateResolution {
        .delivered(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            notificationID: notificationID
        )
    }

    func controlNotificationCreateForSurface(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        replyShapeWire: String?
    ) -> ControlNotificationTargetedDeliveryResolution {
        .delivered(
            workspaceID: workspaceID,
            surfaceID: self.surfaceID,
            windowID: nil,
            notificationID: notificationID
        )
    }

    func controlNotificationCreateForTarget(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        replyShapeWire: String?
    ) -> ControlNotificationTargetedDeliveryResolution {
        .delivered(
            workspaceID: self.workspaceID,
            surfaceID: self.surfaceID,
            windowID: nil,
            notificationID: notificationID
        )
    }

    func controlNotificationClear(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlNotificationClearResolution {
        clearWorkspaceID = workspaceID
        clearSurfaceID = surfaceID
        return .cleared(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    func controlNotificationClearForCaller(
        preferredWorkspaceID: UUID?,
        preferredSurfaceID: UUID?,
        callerTTY: String?,
        preferTTY: Bool
    ) -> ControlNotificationClearResolution {
        clearCallerWorkspaceID = preferredWorkspaceID
        clearCallerSurfaceID = preferredSurfaceID
        return .cleared(workspaceID: workspaceID, surfaceID: surfaceID)
    }
}

@MainActor
private final class UnavailableNotificationControlContext: ControlCommandContext {
    var notificationStrings: ControlNotificationStrings {
        ControlNotificationStrings(
            dismissSelectorRequired: "",
            idRequired: "",
            notFound: "",
            markReadSelectorRequired: "",
            surfaceIDInvalid: "",
            surfaceIDRequiresWorkspace: "",
            targetNotFound: "",
            clearCallerInvalid: "",
            clearCallerSelectorsRequireCaller: "",
            clearCallerScopeConflict: "",
            clearPreferredWorkspaceIDInvalid: "",
            clearPreferredSurfaceIDInvalid: "",
            clearSurfaceIDRequiresWorkspace: "",
            clearWorkspaceIDInvalid: "",
            workspaceNotFound: "workspace missing",
            surfaceNotFound: "surface missing",
            clearUnavailable: "notifications unavailable"
        )
    }

    func controlNotificationClear(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlNotificationClearResolution {
        .tabManagerUnavailable
    }
}

@MainActor
@Suite("ControlCommandCoordinator notification domain")
struct ControlCommandCoordinatorNotificationTests {
    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func createResultsExposeTheCreatedNotificationID() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request("notification.create")))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("notification.create did not return an object success payload: \(result)")
            return
        }
        #expect(payload["id"] == .string(context.notificationID.uuidString))
        #expect(payload["workspace_id"] == .string(context.workspaceID.uuidString))
        #expect(payload["surface_id"] == .string(context.surfaceID.uuidString))
    }

    @Test func targetedCreateResultsExposeTheCreatedNotificationID() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let params: [String: JSONValue] = [
            "workspace_id": .string(context.workspaceID.uuidString),
            "surface_id": .string(context.surfaceID.uuidString),
        ]
        let result = try #require(coordinator.handle(request("notification.create_for_target", params)))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("notification.create_for_target did not return an object success payload: \(result)")
            return
        }
        #expect(payload["id"] == .string(context.notificationID.uuidString))
    }

    @Test func clearAcceptsWorkspaceAndSurfaceSelectors() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let params: [String: JSONValue] = [
            "workspace_id": .string(context.workspaceID.uuidString),
            "surface_id": .string(context.surfaceID.uuidString),
        ]
        let result = try #require(coordinator.handle(request("notification.clear", params)))

        #expect(context.clearWorkspaceID == context.workspaceID)
        #expect(context.clearSurfaceID == context.surfaceID)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("scoped notification.clear did not return an object success payload: \(result)")
            return
        }
        #expect(payload["cleared"] == .bool(true))
        #expect(payload["surface_id"] == .string(context.surfaceID.uuidString))
    }

    @Test func clearCanUseTheNotificationCallerResolution() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let preferredWorkspace = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let result = try #require(coordinator.handle(request("notification.clear", [
            "caller": .bool(true),
            "preferred_workspace_id": .string(preferredWorkspace.uuidString),
        ])))

        #expect(context.clearCallerWorkspaceID == preferredWorkspace)
        #expect(context.clearCallerSurfaceID == nil)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("caller notification.clear did not return an object success payload: \(result)")
            return
        }
        #expect(payload["workspace_id"] == .string(context.workspaceID.uuidString))
    }

    @Test func clearRejectsMalformedCallerSelector() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request("notification.clear", [
            "caller": .object(["unexpected": .bool(true)]),
        ])))

        guard case let .err(code, message, data) = result else {
            Issue.record("malformed caller selector was not rejected: \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid caller")
        #expect(data == nil)
        #expect(context.clearCallerWorkspaceID == nil)
    }

    @Test func clearRejectsCallerOnlySelectorWhenCallerIsOmitted() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request("notification.clear", [
            "preferred_workspace_id": .string(context.workspaceID.uuidString),
        ])))

        guard case let .err(code, message, _) = result else {
            Issue.record("caller-only selector without caller=true was accepted: \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "caller-only selectors require caller=true")
        #expect(context.clearCallerWorkspaceID == nil)
    }

    @Test func clearRejectsCallerOnlySelectorWhenCallerIsFalse() throws {
        let context = NotificationControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request("notification.clear", [
            "caller": .bool(false),
            "prefer_tty": .bool(true),
        ])))

        guard case let .err(code, message, _) = result else {
            Issue.record("caller-only selector with caller=false was accepted: \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "caller-only selectors require caller=true")
        #expect(context.clearCallerWorkspaceID == nil)
    }

    @Test func scopedClearUsesTheInjectedUnavailableMessage() throws {
        let context = UnavailableNotificationControlContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request("notification.clear", [
            "workspace_id": .string(UUID().uuidString),
        ])))

        guard case let .err(code, message, data) = result else {
            Issue.record("unavailable scoped clear did not return an error: \(result)")
            return
        }
        #expect(code == "unavailable")
        #expect(message == "notifications unavailable")
        #expect(data == nil)
    }
}
