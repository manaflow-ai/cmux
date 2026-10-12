import CmuxNextDaemon
import Foundation
import os

/// Serves the `credential` provider family on the local daemon connection
/// (cx-wb5.63): registers after each handshake where the daemon said this
/// is the verified cmux app (`client-hello` `user_origin_allowed`, the same
/// claim the daemon checks on `apps-provider-register`), and answers every
/// `apps-provider-request` of the family through ``CloudCredentialRelay``
/// on the connection that sent it. A non-verified connection never
/// registers, so no credential call reaches it.
@MainActor
final class CloudCredentialProvider {
    typealias Register = @Sendable (AppsProviderRegisterRequest) async throws -> JSONValue
    typealias Reply = @Sendable (AppsProviderResultRequest) async throws -> Void

    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.relay")
    private let relay: CloudCredentialRelay
    /// One task per call in flight, by request id; a cancel ends it.
    private var running: [UInt64: Task<Void, Never>] = [:]

    init(relay: CloudCredentialRelay) {
        self.relay = relay
    }

    /// Calls in flight (tests).
    var inFlight: Int { running.count }

    /// Registers the family when `userOriginAllowed`; returns whether it is
    /// registered. A refusal is logged and not retried on this connection.
    static func register(userOriginAllowed: Bool, send: Register) async -> Bool {
        guard userOriginAllowed else {
            logger.info("credential provider: not the verified app connection; not registered")
            return false
        }
        do {
            _ = try await send(AppsProviderRegisterRequest(families: [CloudCredentialRelay.family]))
            return true
        } catch {
            logger.error("credential provider: register refused: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Handles one local daemon event: a provider call of the family starts
    /// its answer, a cancel stops it. Other events are ignored.
    func handle(_ event: DaemonEvent, reply: @escaping Reply) {
        if let cancel = AppsProviderCancel(event) {
            running.removeValue(forKey: cancel.requestID)?.cancel()
            return
        }
        guard let call = AppsProviderCall(event),
              call.op.hasPrefix(CloudCredentialRelay.family + ".") else { return }
        let relay = relay
        let id = call.requestID
        // task-owner: running[id]; removed when it answers, cancelled by apps-provider-cancel or stop()
        running[id] = Task { [weak self] in
            let answer = await relay.answer(call)
            if !Task.isCancelled {
                do {
                    try await reply(AppsProviderResultRequest(requestID: id, ok: answer.ok, body: answer.body))
                } catch {
                    Self.logger.error("credential provider: result \(id) not sent: \(String(describing: error), privacy: .public)")
                }
            }
            self?.running[id] = nil
        }
    }

    /// Ends every call in flight (sign-out, quit, connection gone).
    func stop() {
        for task in running.values { task.cancel() }
        running.removeAll()
    }
}
