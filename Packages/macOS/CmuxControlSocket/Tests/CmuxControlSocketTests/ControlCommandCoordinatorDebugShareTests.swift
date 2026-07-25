import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugShareControlCommandContext: ControlCommandContext {
    var shareState: JSONValue = .object([
        "status": .string("active"),
        "pending_access_requests": .array([]),
    ])
    var approveResult = false
    var setRoleResult = false
    var stopResult = false
    var approveCall: (user: String, role: String)?
    var setRoleCall: (user: String, role: String)?

    func controlDebugShareState() -> JSONValue {
        shareState
    }

    func controlDebugShareApprove(user: String, role: String) -> Bool {
        approveCall = (user, role)
        return approveResult
    }

    func controlDebugShareSetRole(user: String, role: String) -> Bool {
        setRoleCall = (user, role)
        return setRoleResult
    }

    func controlDebugShareStop() -> Bool {
        stopResult
    }
}

@MainActor
@Suite("ControlCommandCoordinator debug share")
struct ControlCommandCoordinatorDebugShareTests {
    private func makeCoordinator() -> (
        ControlCommandCoordinator,
        FakeDebugShareControlCommandContext
    ) {
        let context = FakeDebugShareControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    @Test func returnsShareStateVerbatim() {
        let (coordinator, context) = makeCoordinator()
        let payload: JSONValue = .object([
            "status": .string("active"),
            "code": .string("share-code"),
        ])
        context.shareState = payload

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.share.state",
            params: [:]
        ))

        #expect(result == .ok(payload))
    }

    @Test func approvesPendingUserWithValidatedRole() {
        let (coordinator, context) = makeCoordinator()
        context.approveResult = true

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.share.approve",
            params: [
                "user": .string("guest-user"),
                "role": .string("editor"),
            ]
        ))

        #expect(context.approveCall?.user == "guest-user")
        #expect(context.approveCall?.role == "editor")
        #expect(result == .ok(.object(["approved": .bool(true)])))
    }

    @Test func rejectsUnknownShareRoleBeforeCallingHost() {
        let (coordinator, context) = makeCoordinator()

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.share.approve",
            params: [
                "user": .string("guest-user"),
                "role": .string("owner"),
            ]
        ))

        #expect(context.approveCall == nil)
        #expect(result == .err(
            code: "invalid_params",
            message: "role must be editor or viewer",
            data: nil
        ))
    }

    @Test func reportsMissingPendingRequest() {
        let (coordinator, context) = makeCoordinator()

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.share.approve",
            params: [
                "user": .string("guest-user"),
                "role": .string("viewer"),
            ]
        ))

        #expect(context.approveCall?.role == "viewer")
        #expect(result == .err(
            code: "not_found",
            message: "Pending access request not found",
            data: nil
        ))
    }

    @Test func updatesConnectedParticipantRole() {
        let (coordinator, context) = makeCoordinator()
        context.setRoleResult = true

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.share.set_role",
            params: [
                "user": .string("guest-user"),
                "role": .string("viewer"),
            ]
        ))

        #expect(context.setRoleCall?.user == "guest-user")
        #expect(context.setRoleCall?.role == "viewer")
        #expect(result == .ok(.object(["updated": .bool(true)])))
    }

    @Test func stopsOnlyAnActiveShare() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handle(ControlRequest(
            id: .int(1),
            method: "debug.share.stop",
            params: [:]
        )) == .err(
            code: "not_found",
            message: "No active share session",
            data: nil
        ))

        context.stopResult = true
        #expect(coordinator.handle(ControlRequest(
            id: .int(2),
            method: "debug.share.stop",
            params: [:]
        )) == .ok(.object(["stopped": .bool(true)])))
    }
}
#endif
