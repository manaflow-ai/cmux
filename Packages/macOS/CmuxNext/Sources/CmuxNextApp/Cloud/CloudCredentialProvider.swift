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
    typealias Invalidate = @Sendable (AppsProviderScopeChangedRequest) async throws -> JSONValue

    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.relay")
    private let relay: CloudCredentialRelay
    /// One task per call in flight, by request id; a cancel ends it.
    private var running: [UInt64: UUID] = [:]
    /// Cancellation does not finish HTTP work: retain it until its task actually returns.
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var ready = false
    private var sessionEnded = false
    private var draining = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(relay: CloudCredentialRelay) {
        self.relay = relay
    }

    /// Calls in flight (tests).
    var inFlight: Int { running.count }

    /// Registers the family when `userOriginAllowed`; returns whether it is
    /// registered. A refusal is logged and not retried on this connection.
    func register(userOriginAllowed: Bool, send: Register, invalidate: Invalidate) async -> Bool {
        guard !sessionEnded else { return false }
        stop()
        let bound = generation
        guard userOriginAllowed else {
            Self.logger.info("credential provider: not the verified app connection; not registered")
            return false
        }
        do {
            _ = try await send(AppsProviderRegisterRequest(families: [CloudCredentialRelay.family]))
            // Probe the invalidation path before serving credentials. Older daemons fail closed.
            _ = try await invalidate(AppsProviderScopeChangedRequest())
            guard generation == bound, !sessionEnded else { return false }
            ready = true
            return true
        } catch {
            Self.logger.error("credential provider: register refused: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// A local account/team/policy change ends pending replies and idle daemon resources.
    func scopeChanged(send: Invalidate) async {
        guard ready, !sessionEnded else { return }
        stop()
        let bound = generation
        do {
            _ = try await send(AppsProviderScopeChangedRequest())
            if generation == bound, !sessionEnded { ready = true }
        } catch {
            Self.logger.error("credential provider: scope invalidation refused: \(String(describing: error), privacy: .public)")
        }
    }

    /// Retires daemon resources and joins credential work before its install key can change.
    func endSession(send: Invalidate?) async {
        let tasks = suspend()
        draining += 1
        defer {
            draining -= 1
            if draining == 0 {
                let waiters = drainWaiters
                drainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        if let send {
            do { _ = try await send(AppsProviderScopeChangedRequest()) }
            catch { Self.logger.error("credential provider: session teardown refused: \(String(describing: error), privacy: .public)") }
        }
        for task in tasks { await task.value }
    }

    /// Waits on teardown completion; the caller must recheck its session before reopening.
    func waitForSessionDrain() async {
        while draining > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    /// A new signed-in session may register after the prior session's drain has ended.
    func beginSession() {
        guard draining == 0 else { return }
        sessionEnded = false
    }

    /// Quit and sign-out stay closed across daemon reconnects until an explicit new sign-in.
    @discardableResult
    func suspend() -> [Task<Void, Never>] {
        sessionEnded = true
        return stop()
    }

    /// Handles one local daemon event: a provider call of the family starts
    /// its answer, a cancel stops it. Other events are ignored.
    func handle(_ event: DaemonEvent, reply: @escaping Reply) {
        if let cancel = AppsProviderCancel(event) {
            if let task = running.removeValue(forKey: cancel.requestID) { pending[task]?.cancel() }
            return
        }
        guard let call = AppsProviderCall(event),
              call.op.hasPrefix(CloudCredentialRelay.family + ".") else { return }
        let relay = relay
        let id = call.requestID
        let enabled = ready && !sessionEnded, key = UUID()
        if let old = running.updateValue(key, forKey: id) { pending[old]?.cancel() }
        // task-owner: pending[key]; retained through cancellation and removed only after its answer ends.
        pending[key] = Task { [weak self] in
            let answer: (ok: Bool, body: JSONValue)
            if enabled && !Task.isCancelled {
                let result = await relay.answer(call)
                answer = (result.ok, result.body)
            } else {
                answer = (false, .object(["code": .string("credential.unavailable"), "message": .string("credential scope is not ready"), "retryable": .bool(true)]))
            }
            if !Task.isCancelled {
                do {
                    try await reply(AppsProviderResultRequest(requestID: id, ok: answer.ok, body: answer.body))
                } catch {
                    Self.logger.error("credential provider: result \(id) not sent: \(String(describing: error), privacy: .public)")
                }
            }
            if self?.running[id] == key { self?.running[id] = nil }
            self?.pending[key] = nil
        }
    }

    /// Cancels calls and returns all unfinished tasks, including earlier cancellations, for draining.
    @discardableResult
    func stop() -> [Task<Void, Never>] {
        generation &+= 1
        ready = false
        let tasks = Array(pending.values)
        for task in tasks { task.cancel() }
        running.removeAll()
        return tasks
    }
}
