public import CmuxNextDaemon
import Foundation

/// Runs Cloud app ops (``CloudAppOp``) on the local daemon's current connection. A refusal is a
/// ``CloudAppOpFailure``; origin `user` is sent only where the daemon allows it (the verified app
/// connection), never upgraded here.
public struct CloudAppOpRunner: Sendable {
    /// A start waits for a paused machine.
    static let timeout: Duration = .seconds(120)
    let connection: @Sendable () async -> DaemonConnection?

    public init(connection: @escaping @Sendable () async -> DaemonConnection?) {
        self.connection = connection
    }

    public var op: CloudAppOp {
        { [connection] op, args, key, origin in
            guard let connection = await connection() else {
                throw CloudAppOpFailure(code: "cmux.cloud.relay_unavailable", message: DaemonError.notConnected.description)
            }
            let allowed = await connection.userOriginAllowed
            let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: args, idempotencyKey: key,
                                         origin: origin == .user && allowed ? .user : .script)
            do {
                return try await connection.request(request, timeout: Self.timeout).value
            } catch DaemonError.command(_, let message, let code, let details, _) {
                throw CloudAppOpFailure(code: code ?? "", message: message, details: details)
            }
        }
    }
}
