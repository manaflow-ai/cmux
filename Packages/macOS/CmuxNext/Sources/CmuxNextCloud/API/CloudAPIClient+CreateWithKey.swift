public import Foundation

extension CloudAPIClient {
    /// `POST /api/vm` with the request's one idempotency key. The server answers
    /// `503 vm_operation_in_progress` when provisioning outlasts its answer deadline and goes on
    /// creating, and `409 vm_create_in_progress` to the same key while it still has no provider
    /// machine: the same key is sent again (the server answers the machine once it exists), up
    /// to ``inProgressRetries`` times, waiting ``inProgressDelay`` between, so a slow create still
    /// ends with its machine and its bootstrap.
    public func createWithKey(name: String?, request: CloudMachineRequest, idlePause: Int?,
                              onSent: @escaping @MainActor @Sendable () async -> Void) async throws -> CloudMachine {
        // This client is pinned to the first send's team: the server scopes a key per team, so a team
        // switched in the app meanwhile must not make the same key a new machine in the other team.
        let send = { try await self.createMachine(displayName: name, memoryMb: request.memoryMb, autosize: request.autosize, idlePauseMinutes: idlePause,
                                                    idempotencyKey: request.idempotencyKey, onSent: onSent) }
        for _ in 0..<Self.inProgressRetries {
            do {
                return try await send()
            } catch let CloudAPIError.http(status, code, _, _, _)
                        where (status == 503 && code == "vm_operation_in_progress") || (status == 409 && code == "vm_create_in_progress") {
                // wakeup-allow: bounded same-key retry of a create the server reports still in progress
                try await ContinuousClock().sleep(for: Self.inProgressDelay)
            }
        }
        return try await send()
    }

    /// 70 tries 15 s apart: past the server's 16-minute provisioning budget (routeDeadline.ts
    /// `create`), with each try's own answer time on top.
    public static let inProgressRetries = 70
    public static let inProgressDelay: Duration = .seconds(15)
}
