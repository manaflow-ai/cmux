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
    static let approvalDenied = "cmux.cloud.approval_denied"
    static let approvalExpired = "cmux.cloud.approval_expired"

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
        let status: Status = switch value["status"]?.stringValue {
        case "provisioning", "starting": .provisioning
        case "running": .running
        case "pausing", "paused": .paused
        case "deleting": .destroyed
        case "failed": .failed
        default: .unknown
        }
        self.init(id: id, provider: "cmux-next", status: status, displayName: value["name"]?.stringValue)
    }
}
