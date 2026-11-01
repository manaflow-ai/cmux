import CmuxNextAgentActivity
public import CmuxNextAgentPane
public import CmuxNextWakeups
public import Foundation

/// The app's connection to acpmux's device-wide chat index. acpmux owns the list (P-RUST,
/// layer-ownership.md rules 1-3): native lists show windows over it (``AcpmuxChatWindows``: acpmux
/// sorts, filters and pages; the main thread holds only visible rows and applies row diffs), and
/// every other reader asks acpmux for what it needs (`_acpmux/chats`, `_acpmux/chat_open`,
/// `_acpmux/chat_projects`). This feed holds no chat of the index: an index change reaches the main
/// actor as a signal for its observers (the projects relay), never as the chat.
@MainActor
public final class ChatsFeed {
    /// The windows over the index that native lists show (the sidebar's chat history, the New Tab
    /// page's cards).
    public let windows = AcpmuxChatWindows()
    private let socket: String
    /// Each drain's line count and main-actor time (the App's debug timings).
    private let drained: @MainActor (Int, Duration) -> Void
    /// The acpmux socket this feed reads (readers that ask acpmux themselves use it).
    public var socketPath: String { socket }
    private var observers: [(owner: () -> AnyObject?, changed: @MainActor () -> Void)] = []
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var reconnect: Task<Void, Never>?
    private var requestID = 2
    /// The open window requests by JSON-RPC id, so an error answer names its window.
    /// Each window request in flight: its window and the spec generation it sent.
    private var windowRequests: [Int: (window: String, generation: UInt64?)] = [:]
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))

    /// - Parameters:
    ///   - socketPath: acpmux's socket.
    ///   - drained: Each drain's line count and main-actor time (the App's debug timings).
    public init(socketPath: String, drained: @escaping @MainActor (Int, Duration) -> Void = { _, _ in }) {
        socket = socketPath
        self.drained = drained
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        reconnect?.cancel()
        subscription?.cancel()
        directoryWatch?.cancel()
    }

    /// Calls `changed` after each index change (a chat added, changed or removed; not a chat's
    /// activity) while `owner` lives, and starts the one long-lived connection for the first.
    public func observe(_ owner: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        observers.append(({ [weak owner] in owner }, changed))
        if subscription == nil, directoryWatch == nil, reconnect == nil { connect() }
    }

    /// Keeps the connection up for the windows while nothing else observes: one idle push
    /// connection, no timers.
    public func keepCurrent() {
        observe(self) {}
    }

    private func connect() {
        reconnect = nil
        guard FileManager.default.fileExists(atPath: socket) else { return watchForSocket() }
        directoryWatch?.cancel()
        directoryWatch = nil
        watchedDirectory = nil
        let connection = AgentActivityLineConnection(path: socket)
        subscription = connection
        // Lines decode on the socket queue and reach the main actor as one batch at a time: a burst
        // of changes is one publish, never a Task per line.
        connection.start(send: Self.watchRequest, decode: Message.init(line:)) { [weak self, weak connection] drain in
            if let connection { self?.apply(drain, from: connection) }
        }
        // The windows' specs go after the watch request, on the same ordered connection.
        windows.connected { [weak self, weak connection] method, params in
            guard let self, let connection, subscription === connection else { return }
            send(method, params, on: connection)
        }
    }

    /// One decoded line of the connection. None carries a chat of the index.
    public nonisolated enum Message: Sendable, Equatable {
        /// The watch is on (its answer); its page is not read.
        case watching
        /// The index changed: a chat was added, changed or removed.
        case indexChanged
        /// A window's rows or row diff (`_acpmux/chats_window_changed`).
        case window(AcpmuxChatWindows.Update)
        /// The answer to request `id` (a window's open or close): whether it is an error, and whether acpmux
        /// answered `ready: false` (its index has not started; the window fills when it does).
        case answered(id: Int, failed: Bool, notReady: Bool)
        /// The daemon dropped a notification or the watch lagged: every window and observer again.
        case lagged

        public init?(line: Data) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            if let id = (message["id"] as? NSNumber)?.intValue, id >= 2 {
                if id == 2, message["result"] is [String: Any] {
                    self = .watching
                } else {
                    let result = message["result"] as? [String: Any]
                    self = .answered(id: id, failed: message["error"] != nil,
                                     notReady: result?["ready"] as? Bool == false && result?["stale"] == nil)
                }
                return
            }
            switch message["method"] as? String {
            case "_acpmux/chat_changed":
                // A chat's activity (attention, preview) reaches the windows as their own diff.
                guard (message["params"] as? [String: Any])?["kind"] as? String != "activity" else { return nil }
                self = .indexChanged
            case "_acpmux/chats_window_changed":
                guard let update = (message["params"] as? [String: Any]).flatMap(AcpmuxChatWindows.Update.init(params:)) else { return nil }
                self = .window(update)
            case "_acpmux/lagged" where (message["params"] as? [String: Any])?["reason"] as? String == "message_too_large":
                // A message past one frame never fits, so asking again would send it again forever:
                // the next change of the index or of its window sends that window again.
                return nil
            case "_acpmux/chats_lagged", "_acpmux/lagged":
                self = .lagged
            default:
                return nil
            }
        }
    }

    /// `initialize`, then the index watch with a one-chat page: the watch is only the change
    /// signal (acpmux answers every list itself).
    private static let watchRequest: Data = {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-chats", "version": "1"], "clientCapabilities": [:]],
        ]
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/chats_watch",
                                     "params": ["enabled": true, "limit": 1]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            payload.append(0x0A)
        }
        return payload
    }()

    /// Applies everything since the last drain, then publishes once: O(lines + changed rows).
    private func apply(_ drain: MainActorLineDrain<Message>, from connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        let started = ContinuousClock.now
        defer { drained(drain.values.count, ContinuousClock.now - started) }
        var changed = false
        for message in drain.values {
            switch message {
            case .watching:
                backoff.reset()
                changed = true
            case .indexChanged:
                changed = true
            case .window(let update):
                windows.apply(update)
            case .answered(let id, let failed, let notReady):
                guard let request = windowRequests.removeValue(forKey: id) else { break }
                if failed {
                    windows.requestFailed(request.window, generation: request.generation)
                } else if notReady {
                    windows.requestNotReady(request.window, generation: request.generation)
                }
            case .lagged:
                windows.resync()
                changed = true
            }
        }
        // Dropped lines (a full batch): every window and observer again.
        if drain.overflowed, !drain.closed {
            windows.resync()
            changed = true
        }
        // The daemon answers again: a window it refused (busy) is asked again.
        if changed { windows.retryFailed() }
        if changed { publish() }
        if drain.closed { lost(connection) }
    }

    /// The window and spec generation a request opens, kept until its answer (nil for any other request).
    nonisolated static func windowRequest(method: String, params: [String: any Sendable]) -> (window: String, generation: UInt64?)? {
        nil
    }

    /// One request on the connection: it is encoded on the connection's own serial queue, so the
    /// main thread does no JSON work and the requests keep their order.
    private func send(_ method: String, _ params: [String: any Sendable], on connection: AgentActivityLineConnection) {
        requestID += 1
        if method == "_acpmux/chats_window", let window = params["window"] as? String {
            windowRequests[requestID] = (window, params["gen"] as? UInt64)
        }
        let id = requestID
        connection.send {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params as [String: Any]]
            guard var line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            line.append(0x0A)
            return line
        }
    }

    private func publish() {
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.changed() }
    }

    private func lost(_ connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        subscription = nil
        windowRequests = [:]
        windows.disconnected()
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "agent-chats.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }

    /// Waits for the socket path to appear by watching its nearest existing directory.
    private func watchForSocket() {
        var directory = (socket as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: directory), directory != "/" {
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard directory != watchedDirectory else { return }
        directoryWatch?.cancel()
        directoryWatch = nil
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.connect() } }
        source.setCancelHandler { close(fd) }
        directoryWatch = source
        watchedDirectory = directory
        source.resume()
    }
}

/// Compatibility for code and extensions that still name the old feed.
public typealias AgentRecentsFeed = ChatsFeed
