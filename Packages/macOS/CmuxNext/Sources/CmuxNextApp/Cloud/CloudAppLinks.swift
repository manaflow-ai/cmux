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

    /// Runs Cloud app ops on `local`'s current connection. `beforeConnect`
    /// runs before each `cloud.machine.connect` (it starts this Mac's link).
    static func runner(local: DaemonService, beforeConnect: (@Sendable () async -> Void)? = nil) -> CloudAppOpRunner {
        let timeout = connectTimeout
        return { op, args, key, origin in
            if op == CloudConnectOpResolver.connectOp { await beforeConnect?() }
            guard let connection = await local.connection else {
                throw CloudLinkError.disconnected(reason: DaemonError.notConnected.description)
            }
            let userOriginAllowed = await connection.userOriginAllowed
            // A pause or a removed machine cancels the connect hop: stop
            // waiting at once instead of up to `connectTimeout`.
            return try await CloudAppRun(op: op, args: args, key: key, origin: origin, userOriginAllowed: userOriginAllowed).run { request in
                try await CloudAppRun.abandoningOnCancel { try await connection.request(request, timeout: timeout).value }
            }
        }
    }

    /// Subscribes `local`'s connection to app events again: the daemon sends
    /// them only to a connection that sent an `apps-` request, and a
    /// reconnected local connection is a new client.
    static func resubscribe(local: DaemonService) async {
        guard let connection = local.connection else { return }
        _ = try? await connection.request(AppsTerminalLinksRequest())
    }

    /// The text a session shows after its link ended: what failed, then the
    /// next step ("click Connect"; v1 does not reconnect by itself). A
    /// failed check's own words stay in the log (``logEnded(_:)``).
    static func endedMessage(_ error: any Error) -> String {
        switch error as? CloudLinkError {
        case .revoked?: CloudStrings.linkRevoked
        case .disconnected?, nil: CloudLinkError.droppedReason(error).map(CloudStrings.linkDisconnected(because:)) ?? CloudStrings.linkDisconnected
        case .helperNotRunning?: CloudStrings.linkHelperNotRunning
        case .openDirectory(let path, let parent)?: CloudStrings.linkOpenDirectory(path, fix: CloudLinkError.chmodFix(path: path, parent: parent))
        case .unsafeSocket?, .invalidAnswer?: CloudStrings.linkCheckFailed
        case .notUp(let state)?: CloudStrings.linkNotReady(state)
        case .failed(let code, let message)?: CloudStrings.linkFailed(message.isEmpty ? code : message)
        case .unsupported?: CloudStrings.linkUnsupported
        }
    }

    /// Logs why a link ended, with the details ``endedMessage(_:)`` leaves out (error level: a shipped build keeps no info).
    static func logEnded(_ error: any Error) {
        logger.error("cloud link ended: \(String(describing: error), privacy: .public)")
    }
}
