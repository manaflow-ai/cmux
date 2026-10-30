import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Cloud ops through the Cloud app server (`cmux/cloud`, contract 2.1):
/// `apps-run` on the local daemon; the server checks the args and origin,
/// keeps the machine projection, and reaches the cmux-next API Worker
/// through the host credential relay (install token, `CloudCredentialProvider`).
/// Never `/api/vm`.
nonisolated struct CloudAppOpFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server's code (`cmux.cloud.<reason>`).
    var code: String
    var message: String
    var details: JSONValue?

    static let approvalPending = "cmux.cloud.approval_pending"
    /// The op needs a paid plan (`cloud.plan.required`).
    static let planRequired = "cmux.cloud.plan_required"

    /// The approval request id (`apr_…`) of an approval code.
    var approvalRequest: String? { details?["request"]?.stringValue }

    var description: String { message.isEmpty ? code : message }
}

/// One Cloud app op: `op`, JSON `args`, an idempotency key for a mutation
/// (nil for a read), and the wire origin.
typealias CloudAppOp = @Sendable (_ op: String, _ args: JSONValue, _ key: String?, _ origin: AppsRunRequest.Origin) async throws -> JSONValue

extension CloudAppLinks {
    /// Runs Cloud app ops on `local`'s current connection. A refusal is a
    /// ``CloudAppOpFailure``; origin `user` is sent only where the daemon
    /// allows it (the verified app connection), never upgraded here.
    static func ops(local: DaemonService) -> CloudAppOp {
        let timeout = connectTimeout
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudAppOpFailure(code: "cmux.cloud.relay_unavailable", message: DaemonError.notConnected.description)
            }
            let allowed = await connection.userOriginAllowed
            let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: args, idempotencyKey: key,
                                         origin: origin == .user && allowed ? .user : .script)
            do {
                return try await connection.request(request, timeout: timeout).value
            } catch DaemonError.command(_, let message, let code, let details, _) {
                throw CloudAppOpFailure(code: code ?? "", message: message, details: details)
            }
        }
    }
}

extension CloudMachine {
    /// A `CloudMachine` record of the cmux-next backend (contract 1.2), as
    /// the Cloud app server answers it.
    init?(next value: JSONValue) {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        // The in-between states stay their own (cloud-machine-ops.ts CloudMachineStatus): a
        // pausing machine is not paused yet, and a deleting one is not gone.
        let status: Status = switch value["status"]?.stringValue {
        case "provisioning": .provisioning
        case "starting": .starting
        case "running": .running
        case "pausing": .pausing
        case "paused": .paused
        case "deleting": .deleting
        case "failed": .failed
        default: .unknown
        }
        // The record's `capabilities` are machine capability names
        // (`agent_session`, …), not provider operations, so the machine
        // declares none and every Cloud action stays available.
        // The idle auto-pause fields, when the backend sends them (`/api/vm` names).
        let minutes = (value["idlePauseMinutes"]?.doubleValue).flatMap { Int(exactly: $0) }
        let idlePause = Self.idlePauseDiagnostics(value["idlePause"])
        self.init(id: id, provider: "cmux-next", status: status, displayName: value["name"]?.stringValue,
                  pauseReason: Self.nextPauseReason(value["pause_reason"] ?? value["pauseReason"]), idlePauseMinutes: minutes,
                  idlePause: idlePause, lastChangeFailure: Self.changeFailure(value["error"]))
        createdBy = value["creator"]?.stringValue
    }

    /// The backend's `pause_reason` (`pauseReason` from an older app server): why cmux paused the
    /// machine by itself. `idle` and the cost backstop `no_report` are both cmux's own idle pause,
    /// which an attach resumes; a VM stopped from inside (`provider_stopped`, `provider_paused`)
    /// and a person's pause (null) carry no reason the app shows.
    static func nextPauseReason(_ value: JSONValue?) -> PauseReason? {
        switch value?.stringValue {
        case "idle", "no_report": .idle
        case "user": .user
        default: nil
        }
    }

    /// The backend's `error` (`{code, message, at}`): why the last pause, resume or resize failed
    /// after the server answered it. Nil for null or a shape this client does not read.
    static func changeFailure(_ value: JSONValue?) -> ChangeFailure? {
        guard let value, case let .object(fields) = value, let code = fields["code"]?.stringValue, !code.isEmpty else { return nil }
        let at = fields["at"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ChangeFailure(code: code, message: fields["message"]?.stringValue ?? "", at: at)
    }

    private static func idlePauseDiagnostics(_ value: JSONValue?) -> IdlePauseDiagnostics? {
        guard let value, case let .object(fields) = value,
              let minutes = fields["minutes"]?.doubleValue.flatMap({ Int(exactly: $0) }),
              let privateAddressKnown = fields["privateAddressKnown"]?.boolValue else { return nil }
        let integer: (String, [String: JSONValue]) -> Int? = { key, object in
            object[key]?.doubleValue.flatMap { Int(exactly: $0) }
        }
        let lastDecision: IdlePauseDiagnostics.LastDecision? = fields["lastDecision"].flatMap { value in
            guard case let .object(decision) = value else { return nil }
            guard let at = integer("at", decision), let outcome = decision["outcome"]?.stringValue,
                  let reason = decision["reason"]?.stringValue,
                  let runValue = decision["run"], case let .object(runFields) = runValue,
                  let checked = integer("checked", runFields), let elapsedMs = integer("elapsedMs", runFields) else { return nil }
            return .init(at: at, outcome: outcome, reason: reason, run: .init(checked: checked, elapsedMs: elapsedMs))
        }
        return .init(minutes: minutes, lastCheckedAt: integer("lastCheckedAt", fields),
                     idleSince: integer("idleSince", fields), lastApiActivityAt: integer("lastApiActivityAt", fields),
                     privateAddressKnown: privateAddressKnown, lastDecision: lastDecision)
    }
}
