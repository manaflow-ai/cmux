import CmuxNextDaemon
import CmuxNextWakeups
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
    private var running: [UInt64: Task<Void, any Error>] = [:]
    /// Where each answer runs, off main (the relay's network calls and the reply).
    private let work: BackgroundWork
    /// Where an answered call leaves ``running``.
    private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - work: The app's one ``BackgroundWork``.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - relay: Answers each call of the family.
    init(work: BackgroundWork, mainWork: MainWorkScheduler, relay: CloudCredentialRelay) {
        self.work = work
        self.mainWork = mainWork
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
        let relay = relay, mainWork = mainWork
        let id = call.requestID
        // task-owner: running[id]; removed when it answers, cancelled by apps-provider-cancel or stop().
        // R-hop: the answer runs off main; only its removal from `running` is a main task.
        running[id] = work.task(.userVisible) { [weak self] in
            let answer = await relay.answer(call)
            if !Task.isCancelled {
                do {
                    try await reply(AppsProviderResultRequest(requestID: id, ok: answer.ok, body: answer.body))
                } catch {
                    Self.logger.error("credential provider: result \(id) not sent: \(String(describing: error), privacy: .public)")
                }
            }
            mainWork.postFromAnyThread(.background, owner: "CloudCredentialProvider.answered") { [weak self] in self?.running[id] = nil }
        }
    }

    /// Ends every call in flight (sign-out, quit, connection gone).
    func stop() {
        for task in running.values { task.cancel() }
        running.removeAll()
    }
}
