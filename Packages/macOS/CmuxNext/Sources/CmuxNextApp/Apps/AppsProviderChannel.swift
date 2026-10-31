import CmuxNextApps
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Observation
import os

/// How the provider channel reaches the supervisor (the local daemon's
/// connection; a fake in tests). A connection is an opaque object: a call is
/// answered on the connection it arrived on, never on a newer one.
@MainActor
struct AppsProviderLink {
    /// The current connection, if any.
    var connection: () -> AnyObject?
    /// `apps-provider-register` on `connection`: nil when accepted, else the
    /// refusal's code (`not_connected`, `timeout`, `failed` for transport errors).
    var register: (_ connection: AnyObject, _ families: [String]) async -> String?
    /// `apps-provider-result` on `connection`.
    var answer: (_ connection: AnyObject, _ requestID: UInt64, _ ok: Bool, _ body: AppJSON) async -> Void
    /// Invalidates the inventory generation synchronously when this provider changes carrier.
    var reset: () -> Void = {}
    /// Whether an original event belongs to the captured registration carrier.
    var accepts: (DaemonEventEnvelope) -> Bool = { _ in true }

    /// Over `daemon`'s connections.
    static func daemon(_ daemon: DaemonService, inventory: AgentInventoryProviderBridge) -> AppsProviderLink {
        var registered: AppProviderSession?
        return AppsProviderLink(connection: { [weak daemon] in (registered as AnyObject?) ?? daemon?.connection }, register: { [weak daemon] connection, families in
            var session: AppProviderSession?
            do {
                guard let stamp = daemon?.store.sideEvents.controlStamp else { return "not_connected" }
                let captured: AppProviderSession
                if let pinned = connection as? AppProviderSession { captured = pinned }
                else if let connection = connection as? DaemonConnection { captured = try await AppProviderSession(connection: connection, expectedStamp: stamp) }
                else { return "not_connected" }
                session = captured
                guard !Task.isCancelled, daemon?.store.sideEvents.controlStamp == stamp,
                      captured.sourceID == stamp.sourceID, captured.serial == stamp.serial else { return "not_connected" }
                registered = captured
                inventory.begin(captured)
                let snapshot = try await captured.register(families: families)
                inventory.registered(captured, snapshot: snapshot)
                return nil
            } catch DaemonError.command(_, _, let code, _, _) {
                inventory.rejected(session)
                return code ?? "refused"
            } catch DaemonError.timedOut {
                inventory.rejected(session)
                return "timeout"
            } catch DaemonError.notConnected, DaemonError.connectionClosed, DaemonError.daemonShutdown {
                inventory.rejected(session)
                return "not_connected"
            } catch {
                inventory.rejected(session)
                return "failed"
            }
        }, answer: { connection, id, ok, body in
            guard let connection = connection as? AppProviderSession else { return }
            try? await connection.answer(requestID: id, ok: ok, body: body.daemonValue)
        }, reset: { registered = nil; inventory.reset() }, accepts: { registered?.matches($0) == true })
    }
}

/// The Mac app as a provider of app op families (`apps-provider-register`):
/// it registers the families it has owner handlers for on every connection
/// that serves `apps-v1`, runs each routed call and answers it on the
/// connection the call arrived on. A call the supervisor cancels (deadline,
/// revoke, host exit) is cancelled here and not answered; a new connection
/// cancels every call of the old one. While an administrator turned apps
/// off, every call, a running one included, is answered `apps.disabled` and
/// no handler runs. A registration refused because another connection still
/// holds a family (`apps.provider.taken`) or by a transient failure is tried
/// again on the same connection with exponential backoff, one at a time.
@MainActor
@Observable
final class AppsProviderChannel {
    /// Refusals tried again on the same connection.
    static let retried: Set<String> = ["apps.provider.taken", "failed", "not_connected", "timeout"]
    /// Families newer daemons know (`apps/provider.rs` `FAMILIES`); an older daemon's
    /// `bad-request` registers again without them.
    static let newerFamilies: Set<String> = ["memory"]

    /// Spacing of registration retries: 0.5 s doubling, at most 30 s, jittered.
    nonisolated static let registerBackoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))

    private struct Running {
        var task: Task<Void, Never>
        var connection: AnyObject
    }

    private let link: AppsProviderLink
    private let backoff: Backoff
    private var capabilities: AppHostCapabilities?
    private var running: [UInt64: Running] = [:]
    /// The connection epoch the families are registered on (set on success only).
    private var registeredEpoch: Int?
    /// The registration in flight or waiting for its retry (one at a time).
    @ObservationIgnored private var registering: Task<Void, Never>?
    private var epoch: Int?
    /// DisabledFeatures `apps`: the reason every call is refused with.
    var turnedOff: String? {
        didSet { if let turnedOff { answerRunningDisabled(turnedOff) } }
    }
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "apps.provider")

    init(link: AppsProviderLink, backoff: Backoff = AppsProviderChannel.registerBackoff) {
        self.link = link
        self.backoff = backoff
    }

    /// The owner handlers (when the control router exists).
    func attach(_ capabilities: AppHostCapabilities) {
        self.capabilities = capabilities
        register()
    }

    /// The connection that serves `apps-v1` now (nil: none). Another epoch is
    /// another connection: the old one's calls are cancelled and the
    /// families registered again.
    func connectionChanged(epoch: Int?) {
        if epoch != self.epoch {
            link.reset()
            for call in running.values { call.task.cancel() }
            running.removeAll()
            registering?.cancel()
            registering = nil
            registeredEpoch = nil
        }
        self.epoch = epoch
        register()
    }

    /// `apps-provider-request` and `apps-provider-cancel` (true; a call of a
    /// family this channel does not serve is left to its own provider);
    /// other events are not the provider's.
    func handle(name: String, payload: CmuxNextDaemon.JSONValue) -> Bool {
        switch name {
        case "apps-provider-request":
            guard let call = RoutedAppCall(AppJSON(payload)) else { return true }
            run(call)
            return true
        case "apps-provider-cancel":
            if let id = AppJSON(payload)["request_id"]?.numberValue.flatMap({ UInt64(exactly: $0) }) {
                running.removeValue(forKey: id)?.task.cancel()
            }
            return true
        default:
            return false
        }
    }

    var isRegistered: Bool { registeredEpoch != nil && registeredEpoch == epoch }

    /// Source-aware production entrypoint; a retained old event cannot become a new call.
    func handle(_ envelope: DaemonEventEnvelope) -> Bool {
        guard case .unknown(let name, let payload) = envelope.event else { return false }
        guard link.accepts(envelope) else { return name.hasPrefix("apps-provider-") }
        return handle(name: name, payload: payload)
    }

    /// The policy turned apps off: every running call ends with `apps.disabled`, on its own connection.
    private func answerRunningDisabled(_ reason: String) {
        let calls = running
        running.removeAll()
        let (ok, body) = RoutedAppCall.disabledAnswer(reason)
        for (id, call) in calls {
            call.task.cancel()
            logger.info("apps-provider-result \(id, privacy: .public) apps.disabled (policy ended a running call)")
            // task-owner: one refusal answer for a call the policy ended
            Task { [link] in await link.answer(call.connection, id, ok, body) }
        }
    }

    private func register() {
        guard let capabilities, let epoch, registeredEpoch != epoch, registering == nil else { return }
        let all = capabilities.families.sorted()
        // task-owner: the connection's registration with its retries; a new epoch cancels it
        registering = Task { [weak self, link, backoff, logger] in
            var backoff = backoff
            var families = all
            while let connection = link.connection() {
                guard let refused = await link.register(connection, families) else {
                    guard !Task.isCancelled, let self, self.epoch == epoch else { return }
                    registeredEpoch = epoch
                    registering = nil
                    return
                }
                // A daemon from before a family existed refuses the whole registration; keep the
                // families it knows rather than losing them all (it restarts on the next handoff).
                if refused == "bad-request", families.contains(where: AppsProviderChannel.newerFamilies.contains) {
                    families.removeAll(where: AppsProviderChannel.newerFamilies.contains)
                    logger.info("apps-provider-register refused: bad-request; registering without the newer families")
                    if families.isEmpty { return }
                    continue
                }
                guard AppsProviderChannel.retried.contains(refused) else {
                    logger.error("apps-provider-register refused: \(refused, privacy: .public); next connection tries again")
                    return
                }
                logger.info("apps-provider-register refused: \(refused, privacy: .public); retry \(backoff.attempt + 1) after backoff")
                // concurrency-allow: Backoff.wait is an async sleep after a refused registration, not a blocking wait.
                do { try await backoff.wait(owner: "AppsProviderChannel.register") } catch { return }
            }
        }
    }

    private func run(_ call: RoutedAppCall) {
        // Only the families this channel registered: another provider on the
        // same connection (the Cloud credential relay) answers its own.
        guard let capabilities, capabilities.handles(call.op), let connection = link.connection() else { return }
        if let turnedOff {
            let (ok, body) = RoutedAppCall.disabledAnswer(turnedOff)
            logger.info("apps-provider-result \(call.requestID, privacy: .public) \(call.op, privacy: .public) apps.disabled")
            // task-owner: one refusal answer while apps are turned off
            Task { [link] in await link.answer(connection, call.requestID, ok, body) }
            return
        }
        // task-owner: one routed app call; apps-provider-cancel, a new connection or the policy cancels it
        let task = Task { [weak self, link] in
            let (ok, body) = await call.answer(with: capabilities)
            guard !Task.isCancelled else { return }
            self?.running[call.requestID] = nil
            await link.answer(connection, call.requestID, ok, body)
        }
        running[call.requestID] = Running(task: task, connection: connection)
    }
}
