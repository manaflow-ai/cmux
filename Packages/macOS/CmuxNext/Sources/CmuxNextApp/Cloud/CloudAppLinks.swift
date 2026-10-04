import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// The Cloud app server (`cmux/cloud`) as the link source of Cloud machine
/// sessions (contract 2.3, C13b): its ops go through `apps-run` on the local
/// daemon, and its `cloud.link.changed` events come back on the same
/// connection as `apps-server-event`.
enum CloudAppLinks {
    /// A connect waits for a paused machine to start and for its link.
    static let connectTimeout: Duration = .seconds(120)

    /// Runs Cloud app ops on `local`'s current connection.
    static func runner(local: DaemonService) -> CloudAppOpRunner {
        let timeout = connectTimeout
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudLinkError.disconnected(reason: DaemonError.notConnected.description)
            }
            let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: .object(args.mapValues(JSONValue.string)),
                                         idempotencyKey: key, origin: origin == .user ? .user : .script)
            do {
                return try JSONEncoder().encode(try await connection.request(request, timeout: timeout))
            } catch DaemonError.command(_, let message, let code, _, _) {
                throw CloudAppOpError(code: code ?? "", message: message)
            }
        }
    }

    /// The link change in a local daemon event, or nil.
    static func change(in event: DaemonEvent) -> CloudLinkChange? {
        guard let event = AppServerEvent(event), event.app == CloudLinkKey.app,
              let line = try? JSONEncoder().encode(event.payload) else { return nil }
        return CloudLinkChange.parse(appServerEvent: line)
    }

    /// The text a session shows after its link ended: "disconnected, click
    /// to connect" (v1 does not reconnect by itself).
    static func endedMessage(_ error: any Error) -> String {
        switch error as? CloudLinkError {
        case .revoked?: CloudStrings.linkRevoked
        case .disconnected?, nil: CloudStrings.linkDisconnected
        case .unsafeSocket(let detail)?, .invalidAnswer(let detail)?: CloudStrings.linkFailed(detail)
        case .failed(_, let message)?: CloudStrings.linkFailed(message)
        case .unsupported?: CloudStrings.linkFailed(String(describing: CloudLinkError.unsupported))
        }
    }
}
