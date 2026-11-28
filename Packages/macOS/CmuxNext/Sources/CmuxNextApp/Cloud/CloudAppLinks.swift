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

    /// Runs Cloud app ops on `local`'s current connection.
    static func runner(local: DaemonService) -> CloudAppOpRunner {
        let timeout = connectTimeout
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudLinkError.disconnected(reason: DaemonError.notConnected.description)
            }
            let userOriginAllowed = await connection.userOriginAllowed
            // A pause or a removed machine cancels the connect hop: stop
            // waiting at once instead of up to `connectTimeout`.
            return try await run(op: op, args: args, key: key, origin: origin, userOriginAllowed: userOriginAllowed) { request in
                try await abandoningOnCancel { try await connection.request(request, timeout: timeout).value }
            }
        }
    }

    /// The `apps-run` origin of a connect: `user` only for a click on a
    /// connection where the daemon said origin `user` is allowed
    /// (`client-hello` `user_origin_allowed`: the verified app, not bound to
    /// an agent, P8); `script` otherwise.
    nonisolated static func wireOrigin(_ origin: CloudLinkOrigin, userOriginAllowed: Bool) -> AppsRunRequest.Origin {
        origin == .user && userOriginAllowed ? .user : .script
    }

    /// One Cloud app op, sent once with ``wireOrigin(_:userOriginAllowed:)``.
    /// A refusal, an origin refusal of `user` included, is thrown as
    /// ``CloudAppOpError`` and shown; it is never sent again with another
    /// origin, so a click the daemon did not admit as the user never becomes
    /// a `script` request. For `cloud.machine.connect` the Cloud server gives
    /// `script` the same authority as `user` (only the answer's `focus`
    /// differs); the app's own `isLive || origin == .user` guard in
    /// `CloudMachineSession.connect` keeps a non-gesture connect from
    /// starting a paused machine.
    nonisolated static func run(op: String, args: [String: String], key: String, origin: CloudLinkOrigin,
                                userOriginAllowed: Bool, send: Send) async throws -> Data {
        let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: .object(args.mapValues(JSONValue.string)),
                                     idempotencyKey: key, origin: wireOrigin(origin, userOriginAllowed: userOriginAllowed))
        do {
            return try JSONEncoder().encode(try await send(request))
        } catch DaemonError.command(_, let message, let code, _, _) {
            if request.origin == .user {
                logger.info("Cloud connect: origin user refused (\(code ?? "", privacy: .public)); not resent")
            }
            throw CloudAppOpError(code: code ?? "", message: message)
        }
    }

    /// Why a link socket was refused after the handshake.
    nonisolated static let localDaemonDetail = "the link socket is this Mac's own daemon"
    nonisolated static let noLocalIdentityDetail = "this Mac's daemon identity is unknown"

    /// The post-handshake check of a link socket (the path check runs before
    /// the connect, ``CloudLinkSocketPolicy``): the daemon behind it must not
    /// be this Mac's own daemon, the same boot (`generation`) or the same
    /// session (`sessionID`: the registry id, lowercased, empty = none).
    /// Without a local identity there is nothing to compare, so the link is
    /// refused (fail closed).
    nonisolated static func checkNotLocal(remote: DaemonIdentity, local: DaemonIdentity?) throws {
        guard let local else { throw CloudLinkError.unsafeSocket(noLocalIdentityDetail) }
        let sameSession = remote.sessionID != nil && remote.sessionID == local.sessionID
        if remote.generation == local.generation || sameSession {
            throw CloudLinkError.unsafeSocket(localDaemonDetail)
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
