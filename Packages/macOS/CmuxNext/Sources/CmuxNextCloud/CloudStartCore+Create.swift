public import CmuxNextDaemon
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

    /// Whether a create refused on try `attempt` (from 1) is asked again with a new key: the machine it made or
    /// claimed was gone before it answered (`cloud.machine.not_found {machine}`, whose contract is "retry with a
    /// new key"), within its bound. An FFI that does not answer asks no more.
    public func createMachineGoneRetries(_ failure: CloudAppOpFailure, attempt: Int) -> Bool {
        struct Request: Encodable { var code: String, message: String, machineNamed: Bool, attempt: Int }
        struct Reply: Decodable { var retries: Bool }
        let request = Request(code: failure.code, message: failure.message, machineNamed: failure.details?["machine"]?.stringValue != nil, attempt: max(attempt, 0))
        return call("cloud_create_machine_gone_retries", request, as: Reply.self)?.retries ?? false
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

    /// The create answer's spare claim report (cmux-platform `withSpareAnswer`) as one log note for the
    /// `created machine` line: `spare_fallback=all_skipped spare_skips={"image":2} spare_skipped=3`, reason codes
    /// and counts only, `spare=none` for an answer with no claim attempt. `spare=unread` when the FFI does not answer.
    public func spareNote(answer: JSONValue) -> String {
        struct Request: Encodable { var answer: JSONValue }
        struct Reply: Decodable { var note: String }
        return call("cloud_create_spare_note", Request(answer: answer), as: Reply.self)?.note ?? "spare=unread"
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
