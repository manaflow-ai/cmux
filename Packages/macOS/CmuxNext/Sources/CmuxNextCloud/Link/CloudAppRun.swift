public import CmuxNextDaemon
public import Foundation
import os

/// One op of the Cloud app server (`cmux/cloud`) as the `apps-run` request the local daemon runs
/// (contract 2.3, C13b); the App's `CloudAppLinks.runner` sends it on the local connection.
///
/// It is sent once, with ``wireOrigin(_:userOriginAllowed:)``. A refusal, an origin refusal of
/// `user` included, is thrown as ``CloudAppOpError`` and shown; it is never sent again with another
/// origin, so a click the daemon did not admit as the user never becomes a `script` request. For
/// `cloud.machine.connect` the Cloud server gives `script` the same authority as `user` (only the
/// answer's `focus` differs); the app's own `isLive || origin == .user` guard in
/// `CloudMachineSession.connect` keeps a non-gesture connect from starting a paused machine.
public struct CloudAppRun: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud")

    /// The `apps-run` request it sends.
    public let request: AppsRunRequest

    public init(op: String, args: [String: String], key: String, origin: CloudLinkOrigin, userOriginAllowed: Bool) {
        request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: .object(args.mapValues(JSONValue.string)),
                                 idempotencyKey: key, origin: Self.wireOrigin(origin, userOriginAllowed: userOriginAllowed))
    }

    /// The `apps-run` origin of a connect: `user` only for a click on a
    /// connection where the daemon said origin `user` is allowed
    /// (`client-hello` `user_origin_allowed`: the verified app, not bound to
    /// an agent, P8); `script` otherwise.
    public static func wireOrigin(_ origin: CloudLinkOrigin, userOriginAllowed: Bool) -> AppsRunRequest.Origin {
        origin == .user && userOriginAllowed ? .user : .script
    }

    /// Sends the request once with `send` and returns its result value as JSON.
    public func run(send: (AppsRunRequest) async throws -> JSONValue) async throws -> Data {
        do {
            return try JSONEncoder().encode(try await send(request))
        } catch DaemonError.command(_, let message, let code, _, _) {
            if request.origin == .user {
                Self.logger.info("Cloud connect: origin user refused (\(code ?? "", privacy: .public)); not resent")
            }
            throw CloudAppOpError(code: code ?? "", message: message)
        }
    }
}
