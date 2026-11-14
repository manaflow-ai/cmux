import Foundation

/// The NEXT Cloud create's same-key retry rules and the power ops' retry, asked of Rust
/// (cmux-cloud-start-core `machine_create`, with their tests; ops `cloud_create_*`, `cloud_power_retries`).
extension CloudStartCore {
    /// Whether the server refused the create before making anything, an answer a same-key Retry would
    /// only replay (the Retry takes a new key). An FFI that does not answer keeps the key: a lost answer
    /// may have made a machine.
    public func isDefinitiveRefusal(_ failure: CloudAppOpFailure) -> Bool {
        struct Request: Encodable { var code: String }
        struct Reply: Decodable { var definitive: Bool }
        return call("cloud_create_definitive_refusal", Request(code: failure.code), as: Reply.self)?.definitive ?? false
    }

    /// The team an app-server create goes to: the install token's team `current`, or, once `request` was
    /// sent, the team of its first send, which `current` must still be (the key is scoped per team).
    /// Throws `changedTeam` otherwise, and when the FFI does not answer: never a second machine.
    public func createTeam(current: String, request: CloudMachineRequest, changedTeam: @autoclosure () -> any Error) throws -> String {
        struct Request: Encodable { var current: String, wasSent: Bool, first: String? }
        struct Reply: Decodable { var team: String? }
        let reply = call("cloud_create_team", Request(current: current, wasSent: request.wasSent, first: request.team), as: Reply.self)
        guard let team = reply?.team else { throw changedTeam() }
        return team
    }

    /// Whether a pause or start that failed with `code` on try `attempt` (from 1) of `attempts` is asked
    /// again with the same key. An FFI that does not answer asks no more.
    public func powerRetries(code: String, attempt: Int, attempts: Int) -> Bool {
        struct Request: Encodable { var code: String, attempt: Int, attempts: Int }
        struct Reply: Decodable { var retries: Bool }
        let request = Request(code: code, attempt: max(attempt, 0), attempts: max(attempts, 0))
        return call("cloud_power_retries", request, as: Reply.self)?.retries ?? false
    }

    /// The relay call of a create pinned to `team`: every call, the first and each same-key retry after an
    /// approval, checks the install token still bills `team` right before it goes out, and is refused, unsent,
    /// if the install switched teams meanwhile (during the confirmation or a retry's backoff). Only a call that
    /// passes marks the request sent.
    public func pinnedRun(team: String, currentTeam: @escaping @Sendable () async throws -> String,
                          sent: @escaping @MainActor @Sendable () async throws -> Void, changedTeam: @escaping @Sendable () -> any Error,
                          ops: @escaping CloudAppOp) -> CloudAppOp {
        { op, args, key, origin in
            guard try await currentTeam() == team else { throw changedTeam() }
            try await sent()
            guard try await currentTeam() == team else { throw changedTeam() }
            return try await ops(op, args, key, origin)
        }
    }
}
