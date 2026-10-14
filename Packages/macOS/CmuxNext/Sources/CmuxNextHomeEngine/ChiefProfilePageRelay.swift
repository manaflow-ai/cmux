public import CmuxNextDaemon
public import Foundation
import os

/// The home-channels page's Chief profile calls (`cmux.chief.profile.*`, hq-ec's New Chief, edit
/// and archive sheets; chief-profile-ws-v1) go to this build's Chief OWNER, where the Chiefs live,
/// not to the build daemon. Route and confirm only, no profile logic (the owner decides):
///
/// - Every call goes on this relay's own `page_relay` connection to the owner, with
///   `client-hello {page: "home-channels"}`, so the owner derives origin `page` and applies the
///   page's allow list (cmux-tui spec/page-router.json).
/// - A call the owner takes only on the person's gesture (create, delete, and an update that
///   names a gesture field) goes out as the user only when a real key or pointer event backs it,
///   one event per call: the host asks `origin.confirmation.issue` on its own trusted connection
///   to the owner (the app's verified main connection) for a token bound to the op, its exact
///   params and this relay connection. Without that event the call goes as the page, and the
///   owner refuses it (`origin.forbidden`, `gesture_required`).
@MainActor
public final class ChiefProfilePageRelay {
    /// The ops the page may send here (page-router.json, home-channels).
    public static let operations: Set<String> = [
        "chief.profile.list", "chief.profile.get", "chief.profile.create", "chief.profile.update",
        "chief.profile.delete", "chief.profile.avatar.get", "chief.profile.avatar.set",
    ]
    /// The update fields the owner changes only on the person's gesture (cmux-tui-core
    /// chief_registry.rs `GESTURE_FIELDS`).
    static let gestureFields: Set<String> = ["effort", "harness", "harnesses", "instructions", "model", "personality", "self_edit", "tools"]

    private static var relays: [ObjectIdentifier: ChiefProfilePageRelay] = [:]

    /// The one relay of `owner` (one page relay connection per owner, shared by its pages).
    public static func shared(for owner: ChiefConversationOwner) -> ChiefProfilePageRelay {
        let key = ObjectIdentifier(owner)
        if let relay = relays[key] { return relay }
        let relay = ChiefProfilePageRelay(owner: owner)
        relays[key] = relay
        return relay
    }

    private weak var owner: ChiefConversationOwner?
    private let wake = RetryWake(owner: "ChiefProfilePageRelay")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chief-profile-relay")
    private let clock: any Clock<Duration>
    /// Every page call answers within this, also when a step below it never does: the page's
    /// sheet then clears busy and shows the error (`cmux.protocol.timeout`). It covers a connect
    /// (two 2 s handshake lines), a confirmation (2 s) and the call (2 s), and one reconnect.
    nonisolated static let callDeadline: Duration = .seconds(10)

    /// The owner process a relay connection serves: a restarted owner (same socket, new process)
    /// is another owner, and its page calls go on a connection to it.
    struct OwnerKey: Equatable {
        var socket: String
        var pid: Int32
        var generation: DaemonGeneration
    }

    /// One page relay connection with its own `client-hello` id (a token is bound to it).
    private struct Relay {
        var connection: DaemonConnection
        var owner: OwnerKey
        var identity: PageRelayIdentity
    }

    private var relay: Relay?
    private var starting: (task: Task<Relay, any Error>, owner: OwnerKey)?
    /// The event uptime of the last gesture a call spent.
    private var spentGesture: TimeInterval?

    init(owner: ChiefConversationOwner, clock: any Clock<Duration> = ContinuousClock()) {
        self.owner = owner
        self.clock = clock
    }

    /// Whether the owner takes `operation` with `params` from the page only on a gesture.
    static func needsGesture(_ operation: String, params: [String: JSONValue]) -> Bool {
        switch operation {
        case "chief.profile.create", "chief.profile.delete": true
        case "chief.profile.update": !gestureFields.isDisjoint(with: params.keys)
        default: false
        }
    }

    /// One page call to the owner. `gestureEvent`: the uptime of the real key or pointer event
    /// that backs this call (`PageCallContext.gestureEvent`), nil without one. It always answers
    /// within ``callDeadline``: the owner's result, its refusal, or a typed error.
    public func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
                     gestureEvent: TimeInterval?) async throws -> JSONValue {
        guard Self.operations.contains(operation) else { throw DaemonError.command(cmd: operation, message: "not a Chief profile operation", code: "unknown_op") }
        // One gesture backs one call; a reconnect inside this call may use it again.
        var gesture = false
        if Self.needsGesture(operation, params: params), let event = gestureEvent, event != spentGesture {
            spentGesture = event
            gesture = true
        }
        let started = ContinuousClock.now
        let elapsed = { Int((ContinuousClock.now - started) / .milliseconds(1)) }
        logger.info("\(operation, privacy: .public): start, gesture \(gesture)")
        do {
            let result = try await PageCallDeadline.answer(within: Self.callDeadline, clock: clock, onTimeout: { [weak self] in
                // A step that never answered: the next call starts on a new connection.
                self?.dropRelay()
                return DaemonError.timedOut("\(operation) (no answer from the Chief owner within \(Self.callDeadline))")
            }) { [self] in
                try await call(operation: operation, params: params, idempotencyKey: idempotencyKey, gesture: gesture)
            }
            logger.info("\(operation, privacy: .public): answered in \(elapsed()) ms")
            return result
        } catch {
            logger.info("\(operation, privacy: .public): failed in \(elapsed()) ms: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The call on the relay connection to the current owner; once more on a new connection when
    /// that connection was closed under it (the owner restarted). A mutation carries its
    /// idempotency key, so the owner applies it once.
    private func call(operation: String, params: [String: JSONValue], idempotencyKey: String?, gesture: Bool) async throws -> JSONValue {
        var attempt = 0
        while true {
            attempt += 1
            guard let owner, let main = owner.connection, let socket = await owner.socketPath(),
                  let identity = owner.identity else { throw DaemonError.notConnected }
            let relay = try await relayConnection(OwnerKey(socket: socket, pid: identity.pid, generation: identity.generation))
            do {
                var origin = JSONValue.object(["claim": .string("page")])
                if gesture {
                    let token = try await confirmationToken(main: main, relay: relay, operation: operation, params: params)
                    origin = .object(["claim": .string("user"), "confirmation": .string(token)])
                }
                return try await ResourceRelayClient(connection: relay.connection).send(
                    operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
            } catch let error as DaemonError where attempt == 1 && Self.isConnectionLost(error) {
                logger.info("\(operation, privacy: .public): relay connection lost (\(error.description, privacy: .public)); again on a new one")
                if self.relay?.connection === relay.connection { dropRelay() }
            }
        }
    }

    nonisolated static func isConnectionLost(_ error: DaemonError) -> Bool {
        switch error {
        case .notConnected, .connectionClosed, .daemonShutdown: true
        default: false
        }
    }

    /// Closes the relay connection; the next call connects again.
    private func dropRelay() {
        guard let relay else { return }
        self.relay = nil
        // task-owner: one close of a connection no call uses any more
        Task { await relay.connection.close() }
    }

    /// The page relay connection to `owner`, the owner process the app's main connection is
    /// attached to now; a new one when that owner restarted or the connection dropped.
    private func relayConnection(_ owner: OwnerKey) async throws -> Relay {
        if let relay, relay.owner == owner, await relay.connection.isReady, await relay.connection.identity.map({
            $0.pid == owner.pid && $0.generation == owner.generation
        }) == true {
            return relay
        }
        // A connect to the same owner in flight is shared; one to another owner is not.
        if let starting, starting.owner == owner { return try await starting.task.value }
        let identity = PageRelayIdentity(page: "home-channels")
        let configuration = DaemonConnection.Configuration(
            clientName: "cmux-next-chief-profile-relay", requiredCapabilities: [], retryWake: wake,
            terminalEnvironment: nil, role: .pageRelay, relayIdentity: identity)
        // task-owner: one connect; ends with its handshake (each line has the request deadline)
        let task = Task { () async throws -> Relay in
            let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: owner.socket), configuration: configuration)
            try await connection.start()
            return Relay(connection: connection, owner: owner, identity: identity)
        }
        starting = (task, owner)
        defer { if starting?.owner == owner { starting = nil } }
        let made = try await task.value
        let old = relay
        relay = made
        if let old, old.connection !== made.connection { await old.connection.close() }
        return made
    }

    /// `origin.confirmation.issue` on the app's trusted main connection to the owner.
    private func confirmationToken(main: DaemonConnection, relay: Relay, operation: String, params: [String: JSONValue]) async throws -> String {
        guard let relayID = relay.identity.connectionID else { throw DaemonError.notConnected }
        let issued = try await ResourceRelayClient(connection: main).send(
            operation: "origin.confirmation.issue",
            params: ["operation": .string(operation), "params_sha256": .string(try ResourceRelayClient.paramsDigest(params)),
                     "relay_connection_id": .string(relayID)],
            idempotencyKey: nil)
        guard case .object(let members) = issued, case .string(let token)? = members["token"] else {
            throw DaemonError.malformedResponse("origin.confirmation.issue")
        }
        return token
    }
}
