import CmuxMobileWire

/// `read task.list` on the rpc channel, from the `task:<host>` projection.
struct TaskListReadHandler: MobileReadHandler {
    let service: MobileTaskService

    func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        try await service.list(frame.params)
    }
}
