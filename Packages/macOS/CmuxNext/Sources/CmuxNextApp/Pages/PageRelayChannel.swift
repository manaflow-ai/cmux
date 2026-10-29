import CmuxNextDaemon
import CmuxNextIPC
import CmuxNextPages
import CmuxNextWakeups
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
///
/// The page host keeps the channels (``WebUIHost/relayChannels``), and a channel
/// holds its daemon connection only while it is used: ``PageRelayIdleClose/delay`` after its last
/// listener and call end, it closes it, and the next call or listen opens a new one. A frozen page
/// pauses its listeners (``PageRelayStreams``), so the daemon has no page-relay client for pages
/// nobody sees.
@MainActor
final class PageRelayChannel {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-relay")

    /// The channel of `page` (a page descriptor id) on `daemon`, kept by `channels` (the app's page
    /// host's): made once per daemon page id, with its idle close on the deadline `idle` makes.
    static func of(page: String, daemon: any PageRelayDaemon, in channels: PageRelayChannels, work: BackgroundWork,
                   idle: () -> any PageRelayIdleDeadline) -> PageRelayChannel {
        let id = relayPageID(page)
        return channels.channel(for: PageRelayChannels.Key(service: ObjectIdentifier(daemon), page: id)) {
            PageRelayChannel(service: daemon, page: id, work: work, idle: idle())
        }
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

    private weak var service: (any PageRelayDaemon)?
    private var relay: DaemonConnection?
    private let identity: PageRelayIdentity
    private var starting: Task<DaemonConnection, any Error>?
    private var warned = false
    /// The event uptime of the last gesture a call spent (``spendGesture(_:)``).
    private var spentGesture: TimeInterval?
    /// Page streams by id: the daemon event each hears, its delivery, and whether its frozen page
    /// paused it (``pauseListener(_:)``: it hears nothing and does not keep the connection).
    private var listeners: [UInt64: (event: String, deliver: @MainActor (CmuxNextDaemon.JSONValue) -> Void, paused: Bool)] = [:]
    private var nextListener: UInt64 = 0
    /// Reads the relay connection's events while it lives (``pumpEvents(_:)``).
    private var pump: Task<Void, Never>?
    /// Closes the relay connection once no listener and no call uses it.
    private let idle: PageRelayIdleClose
    /// Runs the idle close's connection close off the main actor.
    private let work: BackgroundWork

    /// The page does not hear `event` on this daemon (no entry, or an older daemon).
    struct NoSuchEvent: Error {}

    /// - Parameters:
    ///   - service: The daemon service whose relay connections this channel opens (``DaemonService``).
    ///   - page: The daemon page id (``relayPageID(_:)``), or nil for a descriptor that names none.
    ///   - work: Where the idle close's connection close runs.
    ///   - idle: The one-shot deadline of the idle close (a `MainDeadline` in the app).
    init(service: any PageRelayDaemon, page: String?, work: BackgroundWork, idle: any PageRelayIdleDeadline) {
        self.service = service
        self.identity = PageRelayIdentity(page: page)
        self.work = work
        self.idle = PageRelayIdleClose(deadline: idle)
        self.idle.onIdle = { [weak self] in self?.closeConnection() }
    }

    /// One page call: the v2 op `operation` with `params`, as `page`, or as the user with a token
    /// when `context` was confirmed on a native sheet.
    func send(operation: String, params: [String: CmuxNextDaemon.JSONValue], idempotencyKey: String?,
              context: PageCallContext) async throws -> CmuxNextDaemon.JSONValue {
        idle.begin()
        defer { idle.end() }
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
    /// `onEvent`, until ``stopListener(_:)`` ends the returned listener. Throws ``NoSuchEvent`` when
    /// the page's entry does not name it or the daemon has no page relay.
    func listen(event: String, onEvent: @escaping @MainActor (CmuxNextDaemon.JSONValue) -> Void) async throws -> UInt64 {
        idle.begin()
        defer { idle.end() }
        guard let service, service.connection != nil else { throw DaemonError.notConnected }
        guard service.supports(DaemonClientRole.originClaimCapability) else { throw NoSuchEvent() }
        _ = try await relayConnection(service)
        guard identity.events.contains(event) else { throw NoSuchEvent() }
        nextListener += 1
        let id = nextListener
        listeners[id] = (event, onEvent, false)
        // A live listener uses the connection until it stops or pauses.
        idle.begin()
        return id
    }

    /// The idle close: ends the relay connection and its event reader. Every listener was paused or
    /// stopped, so no page lost an event; a paused one resyncs on its thaw, and the page's re-read
    /// opens a connection again (``relayConnection(_:)``) before it reads.
    private func closeConnection() {
        pump?.cancel()
        pump = nil
        guard let connection = relay else { return }
        relay = nil
        // task-owner: one close of the idle relay connection, off main; nothing waits for it
        work.task(.bestEffort) { @Sendable in await connection.close() }
    }

    /// Delivers the relay connection's events to the listeners until the connection ends.
    private func pumpEvents(_ connection: DaemonConnection) {
        pump?.cancel()
        // task-owner: one reader of this relay connection's events; cancelled when a new connection replaces it
        // main-hop-allow: the listeners are this main-actor channel's; each relay event is delivered in its own resume, in order
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
                    case .overflow:
                        // This reader fell behind the connection's bounded backlog
                        // (``DaemonEventRoute``): the events it dropped are lost; the daemon's
                        // subscription is still live.
                        self.resync()
                    case .unknown(name: "overflow", payload: _):
                        // The daemon ended the stream: subscribe again, then re-read, so no
                        // change falls between the re-read and the new stream.
                        // task-owner: one subscribe request with the control deadline
                        // main-hop-allow: the resubscribe awaits the relay connection's actor; the re-read runs in its reply's job
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
                        for listener in self.listeners.values where listener.event == name && !listener.paused {
                            listener.deliver(payload)
                        }
                    default:
                        continue
                    }
                }
            } catch {}
        }
    }

    /// Every live listener re-reads; a paused one resyncs on its page's thaw instead.
    private func resync() {
        for listener in listeners.values where !listener.paused { listener.deliver(.object(["resync": .bool(true)])) }
    }

    /// Whether `context` carries a key or pointer event no earlier call spent.
    private func spendGesture(_ context: PageCallContext) -> Bool {
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else { return false }
        spentGesture = event
        return true
    }

    /// The relay connection; it takes page calls only after its `client-hello` result.
    private func relayConnection(_ service: any PageRelayDaemon) async throws -> DaemonConnection {
        if let relay, await relay.isReady { return relay }
        if let starting { return try await starting.value }
        guard let endpoint = service.endpointProvider else { throw DaemonError.notConnected }
        let configuration = DaemonConnection.Configuration(clientName: "cmux-next-page-relay", retryWake: service.retryWake,
                                                           terminalEnvironment: nil, role: .pageRelay, relayIdentity: identity)
        // main-hop-allow: the connection's start runs on its own actor; this task only hands the started connection back to the channel
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
        let request = V2OriginConfirmationIssueRequest(
            operation: operation, paramsSha256: try ResourceRelayClient.paramsDigest(params, operation: operation),
            relayConnectionID: relayID)
        return try await ResourceOperationClient(connection: main).read(request, as: V2OriginConfirmation.self).token
    }
}

extension PageRelayChannel: PageRelayListeners {
    func pauseListener(_ id: UInt64) {
        guard listeners[id]?.paused == false else { return }
        listeners[id]?.paused = true
        idle.end()
    }

    func resumeListener(_ id: UInt64) {
        guard listeners[id]?.paused == true else { return }
        listeners[id]?.paused = false
        idle.begin()
    }

    func stopListener(_ id: UInt64) {
        guard let listener = listeners.removeValue(forKey: id) else { return }
        if !listener.paused { idle.end() }
    }
}
