import CmuxNextDaemon
import CmuxNextPages
import Foundation
import os

/// The daemon side of React page calls (SECURITY, request-origin.md): page ops go on their own
/// daemon connection with the `page_relay` role, so the daemon derives origin `page` for every
/// one of them, whatever a Swift bug sends. A call is the user's only after a native sheet
/// approved it: the relay asks the main connection for a one-time confirmation token bound to
/// the op, its exact params and this relay connection, and attaches it to that one request. The
/// page never sees the token.
///
/// One relay connection per page (`page-router-v1`): its `client-hello` names the page
/// (`cmux.history` -> `history`), so the daemon applies that page's allow list
/// (cmux-tui/spec/page-router.json). A call the list marks `gesture` goes out with a confirmation
/// token when a real key or pointer event backs it (``PageCallContext/userGesture``).
///
/// Events (`page-events-v1`, cx-hnmbt.9): the relay connection also subscribes when its page hears
/// events (page-router.json `events`); the daemon narrows that stream to them. ``listen(event:onEvent:)``
/// hands each one, as the daemon sent it, to the page streams that asked for it. After a reconnect
/// or an `overflow` (events were lost) every listener gets `{resync: true}` and re-reads.
///
/// Against a daemon without `origin-claim-v1` there is no relay connection: page calls go on the
/// main connection as before, with a logged warning that they are not narrowed.
@MainActor
final class PageRelayChannel {
    private static let logger = Logger(subsystem: "dev.cmux.next", category: "page-relay")
    private struct Key: Hashable {
        let service: ObjectIdentifier
        let page: String?
    }

    private static var channels: [Key: PageRelayChannel] = [:]

    /// The channel of `page` (a page descriptor id) on the local daemon service.
    static func shared(for service: DaemonService, page: String) -> PageRelayChannel {
        let id = relayPageID(page)
        let key = Key(service: ObjectIdentifier(service), page: id)
        if let channel = channels[key] { return channel }
        let channel = PageRelayChannel(service: service, page: id)
        channels[key] = channel
        return channel
    }

    /// The daemon page id of a descriptor id (`cmux.history` -> `history`), or nil when it is not
    /// one (1-64 of `a-z 0-9 -`, a letter first): such a relay serves no page and may call nothing.
    static func relayPageID(_ descriptor: String) -> String? {
        let id = descriptor.hasPrefix("cmux.") ? String(descriptor.dropFirst("cmux.".count)) : descriptor
        guard (1...64).contains(id.count), let first = id.unicodeScalars.first, ("a"..."z").contains(first),
              id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            return nil
        }
        return id
    }

    private weak var service: DaemonService?
    private var relay: DaemonConnection?
    private let identity: PageRelayIdentity
    private var starting: Task<DaemonConnection, any Error>?
    private var warned = false
    /// The event uptime of the last gesture a call spent (``spendGesture(_:)``).
    private var spentGesture: TimeInterval?
    /// Page streams by id: the daemon event each hears and its delivery.
    private var listeners: [UInt64: (event: String, deliver: @MainActor (CmuxNextDaemon.JSONValue) -> Void)] = [:]
    private var nextListener: UInt64 = 0
    /// Reads the relay connection's events while it lives (``pumpEvents(_:)``).
    private var pump: Task<Void, Never>?

    /// The page does not hear `event` on this daemon (no entry, or an older daemon).
    struct NoSuchEvent: Error {}

    init(service: DaemonService, page: String?) {
        self.service = service
        self.identity = PageRelayIdentity(page: page)
    }

    /// One page call: the v2 op `operation` with `params`, as `page`, or as the user with a token
    /// when `context` was confirmed on a native sheet.
    func send(operation: String, params: [String: CmuxNextDaemon.JSONValue], idempotencyKey: String?,
              context: PageCallContext) async throws -> CmuxNextDaemon.JSONValue {
        guard let service, let main = service.connection else { throw DaemonError.notConnected }
        guard service.supports(DaemonClientRole.originClaimCapability) else {
            if !warned {
                warned = true
                Self.logger.warning("the daemon has no origin-claim-v1: page calls are not narrowed to origin page")
            }
            return try await ResourceRelayClient(connection: main).send(operation: operation, params: params, idempotencyKey: idempotencyKey)
        }
        let relay = try await relayConnection(service)
        var origin = CmuxNextDaemon.JSONValue.object(["claim": .string("page")])
        // A native sheet, or the person's own key or pointer event on a call the page's list
        // marks `gesture` (a History delete): the daemon then takes it as the user's. One event
        // backs one such call; a `confirm` call (an app change) needs the sheet.
        let gesture = identity.gestureOperations.contains(operation) && spendGesture(context)
        if context.isConfirmedUser || gesture {
            let token = try await confirmationToken(main: main, relay: relay, operation: operation, params: params)
            origin = .object(["claim": .string("user"), "confirmation": .string(token)])
        }
        return try await ResourceRelayClient(connection: relay).send(
            operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
    }

    /// Hands every `event` (a daemon subscribe event name, `history-changed`) the page hears to
    /// `onEvent`, until the returned cancel runs. Throws ``NoSuchEvent`` when the page's entry does
    /// not name it or the daemon has no page relay.
    func listen(event: String, onEvent: @escaping @MainActor (CmuxNextDaemon.JSONValue) -> Void) async throws -> () -> Void {
        guard let service, service.connection != nil else { throw DaemonError.notConnected }
        guard service.supports(DaemonClientRole.originClaimCapability) else { throw NoSuchEvent() }
        _ = try await relayConnection(service)
        guard identity.events.contains(event) else { throw NoSuchEvent() }
        nextListener += 1
        let id = nextListener
        listeners[id] = (event, onEvent)
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Delivers the relay connection's events to the listeners until the connection ends.
    private func pumpEvents(_ connection: DaemonConnection) {
        pump?.cancel()
        // task-owner: one reader of this relay connection's events; cancelled when a new connection replaces it
        pump = Task { [weak self, weak connection] in
            guard let events = connection?.events else { return }
            var connectedBefore = false
            do {
                for try await envelope in events {
                    guard let self else { return }
                    switch envelope.event {
                    case .connected:
                        // A reconnect: the events while it was down are lost.
                        if connectedBefore { self.resync() }
                        connectedBefore = true
                    case .unknown(name: "overflow", payload: _):
                        // The daemon ended the stream: subscribe again, then re-read, so no
                        // change falls between the re-read and the new stream.
                        // task-owner: one subscribe request with the control deadline
                        Task { [weak self] in
                            do {
                                _ = try await connection?.request(SubscribeRequest(treeEvents: .coarse))
                                self?.resync()
                            } catch {
                                Self.logger.warning("page relay resubscribe failed: \(String(describing: error), privacy: .public)")
                            }
                        }
                    case .unknown(let name, var payload):
                        if case .object(var members) = payload {
                            members.removeValue(forKey: "event")
                            payload = .object(members)
                        }
                        for listener in self.listeners.values where listener.event == name { listener.deliver(payload) }
                    default:
                        continue
                    }
                }
            } catch {}
        }
    }

    private func resync() {
        for listener in listeners.values { listener.deliver(.object(["resync": .bool(true)])) }
    }

    /// Whether `context` carries a key or pointer event no earlier call spent.
    private func spendGesture(_ context: PageCallContext) -> Bool {
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else { return false }
        spentGesture = event
        return true
    }

    /// The relay connection; it takes page calls only after its `client-hello` result.
    private func relayConnection(_ service: DaemonService) async throws -> DaemonConnection {
        if let relay, await relay.isReady { return relay }
        if let starting { return try await starting.value }
        guard let endpoint = service.endpointProvider else { throw DaemonError.notConnected }
        let configuration = DaemonConnection.Configuration(clientName: "cmux-next-page-relay", retryWake: service.retryWake,
                                                           terminalEnvironment: nil, role: .pageRelay, relayIdentity: identity)
        let task = Task { () async throws -> DaemonConnection in
            let connection = DaemonConnection(configuration: configuration, endpointProvider: endpoint)
            try await connection.start()
            return connection
        }
        starting = task
        defer { starting = nil }
        let connection = try await task.value
        // A relay that dropped and was replaced stops reconnecting, so only one connection
        // carries this page's id and events.
        let replaced = relay
        await replaced?.close()
        relay = connection
        pumpEvents(connection)
        // Events while the old connection was down are lost: the pages re-read.
        if replaced != nil { resync() }
        return connection
    }

    /// `origin.confirmation.issue` on the main connection: a single-use token for exactly this
    /// op, params (their canonical SHA-256 as sent) and relay connection.
    private func confirmationToken(main: DaemonConnection, relay: DaemonConnection, operation: String,
                                   params: [String: CmuxNextDaemon.JSONValue]) async throws -> String {
        guard let relayID = identity.connectionID else { throw DaemonError.notConnected }
        let issued = try await ResourceRelayClient(connection: main).send(
            operation: "origin.confirmation.issue",
            params: ["operation": .string(operation), "params_sha256": .string(try ResourceRelayClient.paramsDigest(params, operation: operation)),
                     "relay_connection_id": .string(relayID)],
            idempotencyKey: nil)
        guard case .object(let members) = issued, case .string(let token)? = members["token"] else {
            throw DaemonError.malformedResponse("origin.confirmation.issue")
        }
        return token
    }
}
