import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
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
final class AgentTurnStateFeed {
    /// The app's one feed (nil until `ChatsFeed.started` makes it).
    static var shared: AgentTurnStateFeed?

    private let socket: String
    private let turns: AgentTurnStateStore
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-turn-states")

    init(socketPath: String, turns: AgentTurnStateStore = .shared) {
        socket = socketPath
        self.turns = turns
    }

    /// Starts the watch (idempotent). `localHost` is this Mac's
    /// `install:<id>`: only its chat tabs read these states.
    func start(localHost: @autoclosure () -> String?) {
        if turns.localHost == nil { turns.localHost = localHost() }
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
        // Lines decode on the socket queue; one main-actor batch at a time, never a Task per
        // line (MainActorLineBatch). The main actor only sets the states that changed.
        connection.start(send: Self.watchRequest, decode: Message.init(line:)) { [weak self, weak connection] drain in
            guard let self, let connection, subscription === connection else { return }
            let started = ContinuousClock.now
            defer { DebugTimings.turnStatesApplied(lines: drain.values.count, ContinuousClock.now - started) }
            for message in drain.values { handle(message) }
            // Dropped lines leave the states incomplete: reconnect for a fresh page.
            if drain.overflowed, !drain.closed { connection.cancel() }
            if drain.overflowed || drain.closed { lost(connection) }
        }
    }

    /// `initialize`, then `_acpmux/watch` (id 2), one JSON object per line.
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
        return payload
    }()

    /// One decoded line of the watch (decoded off the main actor).
    nonisolated enum Message: Sendable {
        /// The watch result: every session's state, last message and the muted sessions.
        case page(AgentTurnStates, lastMessages: [String: String], muted: Set<String>, titles: [String: String])
        /// One `_acpmux/session_changed`: the session's new state (nil: none, or purged), last
        /// message and mute.
        case change(session: String, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?)

        init?(line: Data) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            if (message["id"] as? NSNumber)?.intValue == 2, let result = message["result"] as? [String: Any] {
                var states = AgentTurnStates()
                states.reset(result)
                self = .page(states, lastMessages: AgentTurnStates.lastMessages(result), muted: AgentTurnStates.muted(result: result),
                             titles: AgentTurnStates.titles(result))
            } else if message["method"] as? String == "_acpmux/session_changed", let params = message["params"] as? [String: Any],
                      let change = AgentTurnStates.change(params) {
                self = .change(session: change.session, state: change.state, lastMessage: change.lastMessage, muted: change.muted,
                               title: change.title)
            } else {
                return nil
            }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case .page(let states, let lastMessages, let muted, let titles):
            backoff.reset()
            if turns.states != states { turns.states = states }
            if turns.lastMessages != lastMessages { turns.lastMessages = lastMessages }
            if turns.muted != muted { turns.muted = muted }
            if turns.titles != titles { turns.titles = titles }
        case .change(let session, let state, let lastMessage, let muted, let title):
            // Most session records leave the indicator as it was: write (and so redraw the
            // tabs and rows that observe the store) only when the state differs.
            if turns.states[session] != state { turns.states.set(session, state) }
            if turns.lastMessages[session] != lastMessage { turns.lastMessages[session] = lastMessage }
            if turns.muted.contains(session) != muted {
                if muted { turns.muted.insert(session) } else { turns.muted.remove(session) }
            }
            if turns.titles[session] != title { turns.titles[session] = title }
        }
    }

    private func lost(_ connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        subscription = nil
        // A closed watch knows nothing: no stale working dots until it reconnects.
        turns.states.clear()
        turns.lastMessages = [:]
        turns.muted = []
        // Titles stay: a tab keeps reading as its chat while the watch reconnects.
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
