import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextIPC
import CmuxNextPages
import CmuxNextSettings
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
/// events (page-router.json `events`); the daemon narrows that stream to them. ``listen(event:on:onEvent:)``
/// hands each one, as the daemon sent it, to the page streams that asked for it. After a reconnect
/// or an `overflow` (events were lost) every listener gets `{resync: true}` and re-reads.
///
/// Off the main actor (p05-ipc-109): the channel's state is behind a `Mutex`, so a call reads its
/// daemon service in the caller's turn and then runs whole off main: no main-actor job between
/// the page's call and its request on the socket, as Chrome's browser process sends a WebUI's
/// Mojo calls from any sequence (mojo/public/cpp/bindings/shared_remote.h). Events are read off
/// main, their members moved into page values with no JSON text in between, and handed to the
/// main actor at most once per display frame (``FrameOutbox``, ``PageRelayListenerTable``).
///
/// Against a daemon without `origin-claim-v1` there is no relay connection: page calls go on the
/// main connection as before, with a logged warning that they are not narrowed.
///
/// The page host keeps the channels (``WebUIHost/relayChannels``, p13-webui-066), and a channel
/// holds its daemon connection only while it is used: ``PageRelayIdleClose/delay`` after its last
/// listener and call end, it closes it, and the next call or listen opens a new one. A frozen page
/// pauses its listeners (``PageRelayStreams``), so the daemon has no page-relay client for pages
/// nobody sees.
nonisolated final class PageRelayChannel: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-relay")
    /// The most events one frame hands the page; past it the page re-reads once instead.
    static let eventsPerFrame = 256

    /// The channel of `page` (a page descriptor id) on `daemon`, kept by `channels` (the app's page
    /// host's): made once per daemon page id, with its events' frame wake from `events` and its
    /// idle close on the deadline `idle` makes.
    @MainActor
    static func of(page: String, daemon: any PageRelayDaemon, in channels: PageRelayChannels, work: BackgroundWork,
                   events: () -> FrameOutboxWake, idle: () -> any PageRelayIdleDeadline) -> PageRelayChannel {
        let id = relayPageID(page)
        return channels.channel(for: PageRelayChannels.Key(service: ObjectIdentifier(daemon), page: id)) {
            PageRelayChannel(page: id, work: work, events: events(), idle: idle())
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

    /// What a call needs of the daemon service, read in the caller's main-actor turn so the rest
    /// of the call never comes back to main.
    private nonisolated struct Route: Sendable {
        let main: DaemonConnection
        let originClaim: Bool
        let endpoint: DaemonConnection.EndpointProvider?
        let retryWake: RetryWake

        @MainActor init?(_ daemon: any PageRelayDaemon) {
            guard let main = daemon.connection else { return nil }
            self.main = main
            originClaim = daemon.supports(DaemonClientRole.originClaimCapability)
            endpoint = daemon.endpointProvider
            retryWake = daemon.retryWake
        }
    }

    private nonisolated struct State {
        var relay: DaemonConnection?
        var starting: Task<DaemonConnection, any Error>?
        /// Reads the relay connection's events while it lives (``pumpEvents(_:)``).
        var pump: Task<Void, any Error>?
        var warned = false
        /// The event uptime of the last gesture a call spent (``spendGesture(_:)``).
        var spentGesture: TimeInterval?
    }

    private let state = Mutex(State())
    private let identity: PageRelayIdentity
    /// Closes the relay connection once no listener and no call uses it.
    private let idle: PageRelayIdleClose
    /// Runs the event reader and the idle close's connection close off the main actor.
    private let work: BackgroundWork
    /// The page streams listening here, on the main actor; ``PageRelayStreams`` pauses them.
    let listeners: PageRelayListenerTable
    /// The events read off main, waiting for their frame.
    let events: FrameOutbox<PageRelayListenerTable.Event>

    /// The page does not hear `event` on this daemon (no entry, or an older daemon).
    nonisolated struct NoSuchEvent: Error {}

    /// - Parameters:
    ///   - page: The daemon page id (``relayPageID(_:)``), or nil for a descriptor that names none.
    ///   - work: Where the event reader and the idle close's connection close run.
    ///   - wake: Asks for the frame that hands the events read off main to the listeners.
    ///   - idle: The one-shot deadline of the idle close (a `MainDeadline` in the app).
    @MainActor
    init(page: String?, work: BackgroundWork, events wake: FrameOutboxWake, idle: any PageRelayIdleDeadline) {
        identity = PageRelayIdentity(page: page)
        self.work = work
        let close = PageRelayIdleClose(deadline: idle)
        let listeners = PageRelayListenerTable(idle: close)
        self.idle = close
        self.listeners = listeners
        events = FrameOutbox(limit: Self.eventsPerFrame, wake: wake) { batch, gap in
            listeners.deliver(batch, gap: gap)
        }
        close.onIdle = { [weak self] in self?.closeConnection() }
    }

    /// One page call: the v2 op `operation` with `params`, as `page`, or as the user with a token
    /// when `context` was confirmed on a native sheet. Only this turn runs on the main actor; the
    /// request goes out from off main.
    @MainActor
    func send(operation: String, params: [String: CmuxNextDaemon.JSONValue], idempotencyKey: String?,
              context: PageCallContext, on daemon: any PageRelayDaemon) async throws -> CmuxNextDaemon.JSONValue {
        guard let route = Route(daemon) else { throw DaemonError.notConnected }
        idle.begin()
        defer { idle.end() }
        return try await relayCall(operation: operation, params: params, idempotencyKey: idempotencyKey,
                                   context: context, route: route)
    }

    /// Hands every `event` (a daemon subscribe event name, `history-changed`) the page hears to
    /// `onEvent`, until ``PageRelayListenerTable/stopListener(_:)`` ends the returned listener. Throws
    /// ``NoSuchEvent`` when the page's entry does not name it or the daemon has no page relay.
    @MainActor
    func listen(event: String, on daemon: any PageRelayDaemon,
                onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> UInt64 {
        guard let route = Route(daemon) else { throw DaemonError.notConnected }
        guard route.originClaim else { throw NoSuchEvent() }
        idle.begin()
        defer { idle.end() }
        _ = try await relayConnection(route)
        guard identity.events.contains(event) else { throw NoSuchEvent() }
        return listeners.add(event: event, deliver: onEvent)
    }

    @concurrent
    private func relayCall(operation: String, params: [String: CmuxNextDaemon.JSONValue], idempotencyKey: String?,
                           context: PageCallContext, route: Route) async throws -> CmuxNextDaemon.JSONValue {
        guard route.originClaim else {
            if state.withLock({ state in defer { state.warned = true }; return !state.warned }) {
                Self.logger.warning("the daemon has no origin-claim-v1: page calls are not narrowed to origin page")
            }
            return try await ResourceRelayClient(connection: route.main).send(
                operation: operation, params: params, idempotencyKey: idempotencyKey)
        }
        let relay = try await relayConnection(route)
        var origin = CmuxNextDaemon.JSONValue.object(["claim": .string("page")])
        // A native sheet, or the person's own key or pointer event on a call the page's list
        // marks `gesture` (a History delete): the daemon then takes it as the user's. One event
        // backs one such call; a `confirm` call (an app change) needs the sheet.
        let gesture = identity.gestureOperations.contains(operation) && spendGesture(context)
        if context.isConfirmedUser || gesture {
            let token = try await confirmationToken(main: route.main, operation: operation, params: params)
            origin = .object(["claim": .string("user"), "confirmation": .string(token)])
        }
        return try await ResourceRelayClient(connection: relay).send(
            operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
    }

    /// The idle close: ends the relay connection and its event reader. Every listener was paused or
    /// stopped, so no page lost an event; a paused one resyncs on its thaw, and the page's re-read
    /// opens a connection again (``relayConnection(_:)``) before it reads.
    private func closeConnection() {
        let (pump, connection) = state.withLock { state -> (Task<Void, any Error>?, DaemonConnection?) in
            defer {
                state.pump = nil
                state.relay = nil
            }
            return (state.pump, state.relay)
        }
        pump?.cancel()
        guard let connection else { return }
        // task-owner: one close of the idle relay connection, off main; nothing waits for it
        work.task(.bestEffort) { @Sendable in await connection.close() }
    }

    /// Reads the relay connection's events off main until the connection ends, each into the
    /// outbox that hands a frame's worth to the listeners.
    private func pumpEvents(_ connection: DaemonConnection) -> Task<Void, any Error> {
        // task-owner: one reader of this relay connection's events; cancelled when a new connection replaces it
        work.task(.userVisible) { [weak self, weak connection] in
            guard let stream = connection?.events else { return }
            var connectedBefore = false
            for try await envelope in stream {
                guard let self else { return }
                switch envelope.event {
                case .connected:
                    // A reconnect: the events while it was down are lost.
                    if connectedBefore { self.events.offerGap() }
                    connectedBefore = true
                case .unknown(name: "overflow", payload: _):
                    // The daemon ended the stream: subscribe again, then re-read, so no change
                    // falls between the re-read and the new stream.
                    do {
                        _ = try await connection?.request(SubscribeRequest(treeEvents: .coarse))
                        self.events.offerGap()
                    } catch {
                        Self.logger.warning("page relay resubscribe failed: \(String(describing: error), privacy: .public)")
                    }
                case .unknown(let name, let payload):
                    self.events.offer((name: name, payload: Self.pageEvent(payload)))
                default:
                    continue
                }
            }
        }
    }

    /// The page's value of an event's payload, member for member with no JSON text in between,
    /// without the `event` member that named it.
    static func pageEvent(_ payload: CmuxNextDaemon.JSONValue) -> CmuxNextSettings.JSONValue {
        guard case .object(var members) = payload else { return pageValue(payload) }
        members.removeValue(forKey: "event")
        return .object(members.mapValues(pageValue))
    }

    private static func pageValue(_ value: CmuxNextDaemon.JSONValue) -> CmuxNextSettings.JSONValue {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(pageValue))
        case .object(let members): .object(members.mapValues(pageValue))
        }
    }

    /// Whether `context` carries a key or pointer event no earlier call spent.
    private func spendGesture(_ context: PageCallContext) -> Bool {
        guard context.userGesture, let event = context.gestureEvent else { return false }
        return state.withLock { state in
            guard event != state.spentGesture else { return false }
            state.spentGesture = event
            return true
        }
    }

    /// The relay connection; it takes page calls only after its `client-hello` result. Calls that
    /// find it starting share that one start.
    @concurrent
    private func relayConnection(_ route: Route) async throws -> DaemonConnection {
        let (current, pending) = state.withLock { ($0.relay, $0.starting) }
        if let current, await current.isReady { return current }
        if let pending { return try await pending.value }
        guard let endpoint = route.endpoint else { throw DaemonError.notConnected }
        let configuration = DaemonConnection.Configuration(clientName: "cmux-next-page-relay", retryWake: route.retryWake,
                                                           terminalEnvironment: nil, role: .pageRelay, relayIdentity: identity)
        let (start, mine) = state.withLock { state -> (Task<DaemonConnection, any Error>, Bool) in
            if let starting = state.starting { return (starting, false) }
            // task-owner: one connect of this page's relay connection; every call that needs it awaits it
            let start = Task { () async throws -> DaemonConnection in
                let connection = DaemonConnection(configuration: configuration, endpointProvider: endpoint)
                try await connection.start()
                return connection
            }
            state.starting = start
            return (start, true)
        }
        guard mine else { return try await start.value }
        let connection: DaemonConnection
        do {
            connection = try await start.value
        } catch {
            state.withLock { $0.starting = nil }
            throw error
        }
        let pump = pumpEvents(connection)
        // A relay that dropped and was replaced stops reconnecting, so only one connection
        // carries this page's id and events.
        let (replaced, replacedPump) = state.withLock { state -> (DaemonConnection?, Task<Void, any Error>?) in
            defer {
                state.starting = nil
                state.relay = connection
                state.pump = pump
            }
            return (state.relay, state.pump)
        }
        replacedPump?.cancel()
        if let replaced {
            await replaced.close()
            // Events while the old connection was down are lost: the pages re-read.
            events.offerGap()
        }
        return connection
    }

    /// `origin.confirmation.issue` on the main connection: a single-use token for exactly this
    /// op, params (their canonical SHA-256 as sent) and relay connection.
    private func confirmationToken(main: DaemonConnection, operation: String,
                                   params: [String: CmuxNextDaemon.JSONValue]) async throws -> String {
        guard let relayID = identity.connectionID else { throw DaemonError.notConnected }
        let request = V2OriginConfirmationIssueRequest(
            operation: operation, paramsSha256: try ResourceRelayClient.paramsDigest(params, operation: operation),
            relayConnectionID: relayID)
        return try await ResourceOperationClient(connection: main).read(request, as: V2OriginConfirmation.self).token
    }
}
