import CmuxNextDaemon
import Foundation

/// Same-key retry rules for the NEXT Cloud create transport.
public nonisolated struct CloudMachineCreateRetry: Sendable {
    public init() {}

    /// The server refused the create before making anything (no plan, the plan's machine limit or
    /// size, an approval denied or expired, which the contract asks again with a new key), an answer
    /// a same-key Retry would only replay. A lost answer, a timeout or a relay that is down is
    /// uncertain, so it keeps the key.
    public func isDefinitiveRefusal(_ failure: CloudAppOpFailure) -> Bool {
        ["plan_required", "plan.required", "quota_exceeded", "quota.exceeded", "size_locked", "size.locked",
         "approval_denied", "approval.denied", "approval_expired", "approval.expired",
         // cloud.environment.boot: secrets the Vault can't serve yet, no usable snapshot, an environment
         // or snapshot that is gone. Each is stored with the key; a Retry after the fix needs a new one.
         "secrets_unavailable", "no_snapshot_configured", "not_found"]
            .contains { failure.code.hasSuffix($0) }
    }

    /// The team an app-server create goes to: the install token's team `current`, or, once
    /// `request` was sent, the team of its first send, which `current` must still be: the key is
    /// scoped per team, so the same key in another team would be a second machine.
    public func team(current: String, request: CloudMachineRequest, changedTeam: @autoclosure () -> any Error) throws -> String {
        guard request.wasSent, let first = request.team else { return current }
        guard first == current else { throw changedTeam() }
        return first
    }

    /// The relay call of a create pinned to `team`: every call, the first and each same-key retry
    /// after an approval, checks the install token still bills `team` right before it goes out, and
    /// is refused, unsent, if the install switched teams meanwhile (during the confirmation or a
    /// retry's backoff). Only a call that passes marks the request sent.
    public func pinnedRun(team: String, currentTeam: @escaping @Sendable () async throws -> String,
                                      sent: @escaping @MainActor @Sendable () async throws -> Void, changedTeam: @escaping @Sendable () -> any Error, ops: @escaping CloudAppOp) -> CloudAppOp {
        { op, args, key, origin in
            guard try await currentTeam() == team else { throw changedTeam() }
            try await sent()
            guard try await currentTeam() == team else { throw changedTeam() }
            return try await ops(op, args, key, origin)
        }
    }

}
