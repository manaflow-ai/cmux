import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import os

/// The Cloud app server (`cmux/cloud`) as the link source of Cloud machine
/// sessions (contract 2.3, C13b): its ops go through `apps-run` on the local
/// daemon, and its `cloud.link.changed` events come back on the same
/// connection as `apps-server-event`.
enum CloudAppLinks {
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud")

    /// A connect waits for a paused machine to start and for its link.
    static let connectTimeout: Duration = .seconds(120)

    /// Sends one `apps-run` line and returns its result value.
    typealias Send = @Sendable (AppsRunRequest) async throws -> JSONValue

    /// The daemon's Gate A2 refusals of origin `user`: the connection is not
    /// the verified cmux app (`origin.forbidden`) or is bound to an agent
    /// (`apps.origin_forbidden`). Both refuse the line before it runs.
    nonisolated static let userOriginRefusals: Set<String> = ["origin.forbidden", "apps.origin_forbidden"]

    /// Runs Cloud app ops on `local`'s current connection.
    static func runner(local: DaemonService) -> CloudAppOpRunner {
        let timeout = connectTimeout
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudLinkError.disconnected(reason: DaemonError.notConnected.description)
            }
            return try await run(op: op, args: args, key: key, origin: origin) { request in
                try await connection.request(request, timeout: timeout).value
            }
        }
    }

    /// One Cloud app op with the connect's own origin: a click is `user`
    /// (the daemon admits it only from the verified app connection, P8), any
    /// other connect is `script`. The app cannot see the daemon's proof (a
    /// signed build is proved by its code signature on the daemon side), so
    /// when the daemon refuses `user` with a Gate A2 code, the click is sent
    /// once more as `script` with the same key: the refused line ran nothing,
    /// and `script` asks for less authority, never more.
    nonisolated static func run(op: String, args: [String: String], key: String, origin: CloudLinkOrigin, send: Send) async throws -> Data {
        func request(_ origin: AppsRunRequest.Origin) -> AppsRunRequest {
            AppsRunRequest(app: CloudLinkKey.app, op: op, args: .object(args.mapValues(JSONValue.string)),
                           idempotencyKey: key, origin: origin)
        }
        do {
            do {
                return try JSONEncoder().encode(try await send(request(origin == .user ? .user : .script)))
            } catch DaemonError.command(_, _, let code?, _, _) where origin == .user && userOriginRefusals.contains(code) {
                logger.info("Cloud connect: origin user refused (\(code, privacy: .public)); sent as script")
                return try JSONEncoder().encode(try await send(request(.script)))
            }
        } catch DaemonError.command(_, let message, let code, _, _) {
            throw CloudAppOpError(code: code ?? "", message: message)
        }
    }

    /// Subscribes `local`'s connection to app events again: the daemon sends
    /// them only to a connection that sent an `apps-` request, and a
    /// reconnected local connection is a new client.
    static func resubscribe(local: DaemonService) async {
        guard let connection = local.connection else { return }
        _ = try? await connection.request(AppsTerminalLinksRequest())
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
