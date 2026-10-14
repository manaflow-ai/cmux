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
    private let identity = PageRelayIdentity(page: "home-channels")
    private let wake = RetryWake(owner: "ChiefProfilePageRelay")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chief-profile-relay")
    private var relay: (connection: DaemonConnection, socket: String)?
    private var starting: (task: Task<DaemonConnection, any Error>, socket: String)?
    /// The event uptime of the last gesture a call spent.
    private var spentGesture: TimeInterval?

    init(owner: ChiefConversationOwner) {
        self.owner = owner
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
    /// that backs this call (`PageCallContext.gestureEvent`), nil without one.
    public func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
                     gestureEvent: TimeInterval?) async throws -> JSONValue {
        guard Self.operations.contains(operation) else { throw DaemonError.command(cmd: operation, message: "not a Chief profile operation", code: "unknown_op") }
        let started = ContinuousClock.now
        let ms = { Int((ContinuousClock.now - started) / .milliseconds(1)) }
        logger.info("\(operation, privacy: .public): start gesture=\(gestureEvent != nil)")
        do {
            guard let owner, let main = owner.connection, let socket = await owner.socketPath() else { throw DaemonError.notConnected }
            let relay = try await relayConnection(socket: socket)
            logger.info("\(operation, privacy: .public): relay ready at \(ms()) ms")
            var origin = JSONValue.object(["claim": .string("page")])
            if Self.needsGesture(operation, params: params), let event = gestureEvent, event != spentGesture {
                spentGesture = event
                let token = try await confirmationToken(main: main, operation: operation, params: params)
                logger.info("\(operation, privacy: .public): confirmation at \(ms()) ms")
                origin = .object(["claim": .string("user"), "confirmation": .string(token)])
            }
            let result = try await ResourceRelayClient(connection: relay).send(
                operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
            logger.info("\(operation, privacy: .public): answered at \(ms()) ms")
            return result
        } catch {
            logger.info("\(operation, privacy: .public): failed at \(ms()) ms: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The page relay connection to the owner at `socket`; a new one when the owner moved.
    private func relayConnection(socket: String) async throws -> DaemonConnection {
        if let relay, relay.socket == socket, await relay.connection.isReady { return relay.connection }
        // A connect to the same owner in flight is shared; one to an owner that moved is not.
        if let starting, starting.socket == socket { return try await starting.task.value }
        let configuration = DaemonConnection.Configuration(
            clientName: "cmux-next-chief-profile-relay", requiredCapabilities: [], retryWake: wake,
            terminalEnvironment: nil, role: .pageRelay, relayIdentity: identity)
        // task-owner: one connect; ends with its handshake
        let task = Task { () async throws -> DaemonConnection in
            let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: socket), configuration: configuration)
            try await connection.start()
            return connection
        }
        starting = (task, socket)
        defer { if starting?.socket == socket { starting = nil } }
        let connection = try await task.value
        await relay?.connection.close()
        relay = (connection, socket)
        return connection
    }

    /// `origin.confirmation.issue` on the app's trusted main connection to the owner.
    private func confirmationToken(main: DaemonConnection, operation: String, params: [String: JSONValue]) async throws -> String {
        guard let relayID = identity.connectionID else { throw DaemonError.notConnected }
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
