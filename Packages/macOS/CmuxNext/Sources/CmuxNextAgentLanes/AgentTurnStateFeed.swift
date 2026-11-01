public import CmuxNextAgentActivity
public import CmuxNextBridge
import CmuxNextWakeups
import Foundation
import os

/// Every local acpmux session's turn state for the working and needs-input
/// indicators (`AgentTurnStateStore`): one long-lived `_acpmux/watch`
/// connection whose `_acpmux/session_changed` pushes keep it current, so
/// nothing polls. It starts with the app's Chats feed (`ChatsFeed.started`).
/// When the socket is absent it waits for a directory change on the socket's
/// path; a lost connection clears the states and reconnects with `Backoff`.
@MainActor
public final class AgentTurnStateFeed {
    /// The app's one feed (nil until `ChatsFeed.started` makes it).
    public static var shared: AgentTurnStateFeed?
    /// Each drain's line count and main-actor time (the App's `debug.timings`, cx-9c8m.6).
    public static var drained: ((Int, Duration) -> Void)?
    /// A session the app's own acpmux deleted (``deletesSession(_:)``): the app deletes what it
    /// kept for it (its chat uploads).
    public static var purged: ((String) -> Void)?

    /// Whether a `_acpmux/session_changed`'s params say this acpmux deleted one of its own chats:
    /// `purged`, but not a peer's or the Cloud VM's row (`peer`: that daemon's copy left, as every
    /// chat's does when a Cloud lease ends, under the chat's own id) and not the closed copy Bring
    /// Back replaces under the same id (`replaced`). Those chats still exist.
    public nonisolated static func deletesSession(_ params: [String: Any]) -> Bool {
        params["kind"] as? String == "purged" && params["peer"] == nil && params["replaced"] as? Bool != true
    }

    private let socket: String
    private let turns: AgentTurnStateStore
    /// The store's source of this watch (``AgentTurnStateStore/localSource`` for the app's
    /// own acpmux, else the mirrored host).
    private let source: String
    private let lanes: AgentLaneStore
    /// A session of acpmux peer `peer` changed on the app's own acpmux (not a mirror's), `stale`
    /// when the peer dropped and its rows turned unreachable: its sessions change when it connects
    /// and when it drops. The app offers a peer that connects later to the daemon update
    /// (`DaemonUpdates.peerSessionChanged`). Called once per such change: keep it O(1).
    private let peerSessionChanged: (@MainActor (_ peer: String, _ stale: Bool) -> Void)?
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    /// This connection's usage read (``usageRequest(cursor:)``): its numbers until the watch's page
    /// arrives (the page would replace them), whether the page did, and the pages it read.
    private var usageRead: (numbers: [String: AgentChatDetail], paged: Bool, pages: Int) = ([:], false, 0)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-turn-states")

    /// - Parameters:
    ///   - socketPath: The acpmux socket to watch.
    ///   - turns: The store the watch writes.
    ///   - lanes: The activity lanes the watch writes; a mirrored acpmux's watch passes its own
    ///     store, since a page replaces every lane.
    ///   - mirroring: Nil for this Mac's own acpmux; else the host (`chief:<id>`) of another
    ///     acpmux on this Mac whose chats the store also mirrors.
    ///   - peerSessionChanged: each change of an acpmux peer's session on this Mac's own acpmux.
    public init(socketPath: String, turns: AgentTurnStateStore = .shared, lanes: AgentLaneStore = .shared,
                mirroring host: String? = nil, peerSessionChanged: (@MainActor (_ peer: String, _ stale: Bool) -> Void)? = nil) {
        socket = socketPath
        self.turns = turns
        self.lanes = lanes
        self.peerSessionChanged = peerSessionChanged
        lanes.socketPath = socketPath
        source = host ?? AgentTurnStateStore.localSource
        if let host { turns.mirroredHosts.insert(host) }
    }

    /// The app's own acpmux pushed peer `peer`'s link state (`_acpmux/peer_state_changed`:
    /// `connected` only after the handshake), or, with `peer` nil, its watch (re)opened and the
    /// whole peer list may have moved. Only this Mac's own daemon's pushes reach it: a mirrored
    /// acpmux's (`mirroring`) never call it, and a peer's own states never travel over a peer link.
    /// Called once per change (the daemon sends one only when a state changes): keep it O(1).
    public var peerStateChanged: (@MainActor (_ peer: String?, _ state: String?) -> Void)?

    /// Whether this watch mirrors another acpmux than the app's own (it leaves `watching` alone).
    private var isMirror: Bool { source != AgentTurnStateStore.localSource }

    /// Starts the watch (idempotent). `localHost` is this Mac's
    /// `install:<id>`: only its chat tabs read these states.
    public func start(localHost: @autoclosure () -> String?) {
        if !isMirror, turns.localHost == nil { turns.localHost = localHost() }
        if subscription == nil, directoryWatch == nil, reconnect == nil { connect() }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            reconnect?.cancel()
            subscription?.cancel()
            directoryWatch?.cancel()
        }
    }

    // MARK: Watch

    private func connect() {
        reconnect = nil
        guard FileManager.default.fileExists(atPath: socket) else { return watchForSocket() }
        directoryWatch?.cancel()
        directoryWatch = nil
        watchedDirectory = nil
        logger.info("agent turn states: watching \(self.socket, privacy: .public)")
        let connection = AgentActivityLineConnection(path: socket)
        subscription = connection
        usageRead = ([:], false, 0)
        // Lines decode on the socket queue; one main-actor batch at a time, never a Task per
        // line (MainActorLineBatch). The main actor only sets the states that changed.
        connection.start(send: Self.watchRequest, decode: Message.init(line:)) { [weak self, weak connection] drain in
            guard let self, let connection, subscription === connection else { return }
            let started = ContinuousClock.now
            defer { Self.drained?(drain.values.count, ContinuousClock.now - started) }
            for message in drain.values { handle(message) }
            // Dropped lines leave the states incomplete: reconnect for a fresh page.
            if drain.overflowed, !drain.closed { connection.cancel() }
            if drain.overflowed || drain.closed { lost(connection) }
        }
    }

    /// `initialize`, then `_acpmux/watch` (id 2), then the usage read (id 3,
    /// ``usageRequest(cursor:)``), one JSON object per line.
    static let watchRequest: Data = {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-turn-states", "version": "1"], "clientCapabilities": [:]],
        ]
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": ["enabled": true]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            payload.append(0x0A)
        }
        return payload + usageRequest(cursor: nil)
    }()

    /// The most pages one usage read follows (`SESSION_PAGE`-sized byte pages: far past any real list).
    static let usagePages = 50

    /// `_acpmux/sessions` with `usage: true` (id 3), from `cursor` on: acpmux reads each chat's
    /// harness records first (one pass at most every 5 s, waited for at most 750 ms) instead of
    /// answering the last pass's numbers, or none when nothing asked since it started. The watch's
    /// own list carries only those, so the hover card's usage row stayed empty or stale. Asked
    /// once each time the watch (re)connects, never on a timer: after it, each chat's turn end
    /// brings its own fresh numbers over `_acpmux/session_changed`.
    static func usageRequest(cursor: String?) -> Data {
        var params: [String: Any] = ["usage": true]
        if let cursor { params["cursor"] = cursor }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "_acpmux/sessions", "params": params]
        var line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        line.append(0x0A)
        return line
    }

    /// One decoded line of the watch (decoded off the main actor).
    nonisolated enum Message: Sendable {
        /// The watch result: every session's state, last message and the muted sessions.
        case page(AgentTurnStates, lastMessages: [String: String], muted: Set<String>, titles: [String: String],
                  generatedTitles: [String: String], details: [String: AgentChatDetail], lanes: [String: AgentActivityLane],
                  startedBy: [String: String], sessionNames: [String: String] = [:])
        /// One `_acpmux/session_changed`: the session's new state (nil: none, or purged), last
        /// message and mute, the session that started it (nil for a root, or purged), whether this
        /// acpmux deleted it (``deletesSession(_:)``), and for a session of an acpmux peer, that
        /// peer and whether its row went stale (the peer dropped); nil for a purged one.
        case change(session: String, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?,
                    generatedTitle: String?, detail: AgentChatDetail?, lane: AgentActivityLane?, startedBy: String?,
                    deleted: Bool = false, peer: (name: String, stale: Bool)? = nil, sessionName: String? = nil)
        /// A page of the usage read (id 3): each listed chat's usage numbers that acpmux read, and
        /// the cursor of the next page (nil: the last).
        case usage([String: AgentChatDetail], next: String?)
        /// One `_acpmux/peer_state_changed`: peer `peer`'s link is now `state` (connected,
        /// connecting, degraded, reconnecting or offline; a removed peer's last is offline).
        case peerState(peer: String, state: String)

        init?(line: Data) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            if (message["id"] as? NSNumber)?.intValue == 2, let result = message["result"] as? [String: Any] {
                var states = AgentTurnStates()
                states.reset(result)
                self = .page(states, lastMessages: AgentTurnStates.lastMessages(result), muted: AgentTurnStates.muted(result: result),
                             titles: AgentTurnStates.titles(result), generatedTitles: AgentTurnStates.titles(result, includingPrompt: false),
                             details: AgentChatDetail.details(result), lanes: Self.lanes(result),
                             startedBy: AgentTurnStateStore.startedBy(result), sessionNames: AgentTurnStates.sessionNames(result))
            } else if (message["id"] as? NSNumber)?.intValue == 3, let result = message["result"] as? [String: Any] {
                let next = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                self = .usage(AgentChatDetail.details(result).filter(\.value.hasUsage), next: next)
            } else if message["method"] as? String == "_acpmux/session_changed", let params = message["params"] as? [String: Any],
                      let change = AgentTurnStates.change(params) {
                let purged = params["kind"] as? String == "purged"
                let summary = purged ? nil : params["session"] as? [String: Any]
                self = .change(session: change.session, state: change.state, lastMessage: change.lastMessage, muted: change.muted,
                               title: change.title, generatedTitle: change.generatedTitle,
                               detail: (params["session"] as? [String: Any]).flatMap(AgentChatDetail.of(summary:)),
                               lane: summary.flatMap { AgentActivityLane.of(summary: $0, id: change.session) },
                               startedBy: summary.flatMap(AgentTurnStateStore.startedBy(summary:)),
                               deleted: AgentTurnStateFeed.deletesSession(params),
                               peer: (params["peer"] as? String).flatMap { name in
                                   summary.map { (name: name, stale: $0["stale"] as? Bool == true) }
                               }, sessionName: change.sessionName)
            } else if message["method"] as? String == "_acpmux/peer_state_changed", let params = message["params"] as? [String: Any],
                      let peer = params["peer"] as? String, !peer.isEmpty, let state = params["state"] as? String {
                self = .peerState(peer: peer, state: state)
            } else {
                return nil
            }
        }

        /// The lane of every session of a watch result (this Mac's and its acpmux peers').
        static func lanes(_ result: [String: Any]) -> [String: AgentActivityLane] {
            var lanes: [String: AgentActivityLane] = [:]
            for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                if let lane = AgentActivityLane.of(summary: summary) { lanes[lane.id] = lane }
            }
            return lanes
        }
    }

    func handle(_ message: Message) {
        switch message {
        case .page(let states, let lastMessages, let muted, let titles, let generatedTitles, let details, let lanes, let startedBy, let sessionNames):
            backoff.reset()
            if !isMirror, !turns.watching { turns.watching = true }
            turns.replace(states: states, lastMessages: lastMessages, muted: muted, titles: titles,
                          generatedTitles: generatedTitles, sessionNames: sessionNames, details: details, source: source)
            turns.replaceStartedBy(startedBy, source: source)
            if self.lanes.lanes != lanes { self.lanes.lanes = lanes }
            if !self.lanes.live { self.lanes.live = true }
            // A fresh page (the first, or after a reconnect): the peer list is read again.
            if !isMirror { peerStateChanged?(nil, nil) }
            // A usage read that answered first: its numbers are newer than the page's.
            usageRead.paged = true
            if !usageRead.numbers.isEmpty { turns.applyUsage(usageRead.numbers, source: source) }
        case .change(let session, let state, let lastMessage, let muted, let title, let generatedTitle, let detail, let lane,
                     let startedBy, let deleted, let peer, let sessionName):
            // Most session records leave the indicator as it was: the store writes (and so
            // redraws the tabs and rows that read this session) only what differs.
            turns.apply(session: session, sessionName: sessionName, state: state, lastMessage: lastMessage, muted: muted, title: title,
                        generatedTitle: generatedTitle, detail: detail, source: source)
            turns.setStartedBy(startedBy, session: session, source: source)
            if lanes.lanes[session] != lane { lanes.lanes[session] = lane }
            if deleted, !isMirror { Self.purged?(session) }
            if let peer, !isMirror { peerSessionChanged?(peer.name, peer.stale) }
        case .usage(let numbers, let next):
            usageRead.numbers.merge(numbers) { $1 }
            usageRead.pages += 1
            if usageRead.paged { turns.applyUsage(numbers, source: source) }
            if let next, usageRead.pages < Self.usagePages { subscription?.send(Self.usageRequest(cursor: next)) }
        case .peerState(let peer, let state):
            if !isMirror { peerStateChanged?(peer, state) }
        }
    }

    private func lost(_ connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        subscription = nil
        // A closed watch knows nothing: no stale working dots until it reconnects.
        if !isMirror { turns.watching = false }
        // Titles stay: a tab keeps reading as its chat while the watch reconnects.
        turns.clearLive(source: source)
        lanes.lanes = [:]
        lanes.live = false
        logger.info("agent turn states: watch closed")
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "agent-turn-states.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }

    /// Waits for the socket to appear: watches the nearest directory on its
    /// path that exists (the daemon's home, else the folder it will be made
    /// in) and connects on each change there. An event, not a poll.
    private func watchForSocket() {
        var directory = (socket as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: directory), directory != "/" {
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard directory != watchedDirectory else { return }
        logger.info("agent turn states: waiting for the socket in \(directory, privacy: .public)")
        directoryWatch?.cancel()
        directoryWatch = nil
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.connect() }
        }
        source.setCancelHandler { close(fd) }
        directoryWatch = source
        watchedDirectory = directory
        source.resume()
    }
}
