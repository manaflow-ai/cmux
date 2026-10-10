import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import os

/// The device-wide acpmux chat index for sidebar and palette clients.
@MainActor
final class ChatsFeed {
    private(set) var chats: [AcpmuxChat] = []
    private(set) var isEnabled = true
    private(set) var isReady = false
    private let socket: String
    private var store = AcpmuxChatsStore()
    private var observers: [(owner: () -> AnyObject?, changed: @MainActor () -> Void)] = []
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var reconnect: Task<Void, Never>?
    private var requestID = 2
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-chats")

    init(socketPath: String) { socket = socketPath }

    isolated deinit {
        reconnect?.cancel()
        subscription?.cancel()
        directoryWatch?.cancel()
    }

    /// Starts one long-lived watch for the first live observer.
    func observe(_ owner: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        observers.append(({ [weak owner] in owner }, changed))
        if subscription == nil, directoryWatch == nil, reconnect == nil { connect() }
    }

    /// Keeps the mirror current for the palette chats page and Open Chat while
    /// no sidebar shows Chats: one idle push connection, no timers.
    func keepCurrent() {
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
        // Lines decode on the socket queue (the first page is megabytes) and reach the main
        // actor as one batch at a time: a burst of changes is one publish, never a Task per line.
        connection.start(send: Self.watchRequest(limit: 5000), decode: Message.init(line:)) { [weak self, weak connection] drain in
            if let connection { self?.apply(drain, from: connection) }
        }
    }

    /// One decoded line of the watch.
    nonisolated enum Message: Sendable {
        /// A page response: the whole mirror, sorted off the main actor.
        case page(store: AcpmuxChatsStore, ready: Bool, enabled: Bool)
        case change(AcpmuxChatsStore.Change)
        case lagged

        init?(line: Data) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            if let id = (message["id"] as? NSNumber)?.intValue, id == 2 || id >= 3,
               let result = message["result"] as? [String: Any] {
                var store = AcpmuxChatsStore()
                store.reset(result)
                self = .page(store: store, ready: result["ready"] as? Bool ?? false, enabled: result["enabled"] as? Bool ?? true)
                return
            }
            switch message["method"] as? String {
            case "_acpmux/chat_changed":
                guard let change = (message["params"] as? [String: Any]).flatMap(AcpmuxChatsStore.change(from:)) else { return nil }
                self = .change(change)
            case "_acpmux/chats_lagged":
                self = .lagged
            default:
                return nil
            }
        }
    }

    private static func watchRequest(limit: Int) -> Data {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-chats", "version": "1"], "clientCapabilities": [:]],
        ]
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/chats_watch",
                                     "params": ["enabled": true, "limit": limit]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            payload.append(0x0A)
        }
        return payload
    }

    /// Applies everything since the last drain, then publishes once.
    private func apply(_ drain: MainActorLineDrain<Message>, from connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        var changed = false
        var lagged = false
        for message in drain.values {
            switch message {
            case .page(let page, let ready, let enabled):
                store = page
                isReady = ready
                isEnabled = enabled
                backoff.reset()
                lagged = false
                changed = true
            case .change(let change):
                store.apply(change)
                changed = true
            case .lagged:
                lagged = true
            }
        }
        // Dropped lines (a full batch) leave the mirror incomplete, like a lag: fetch a fresh page.
        if lagged || drain.overflowed { requestList() }
        if changed { publish() }
        if drain.closed { lost(connection) }
    }

    private func requestList() {
        guard let subscription else { return }
        requestID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": "_acpmux/chats",
                                       "params": ["limit": 5000]]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        var line = data
        line.append(0x0A)
        subscription.send(line)
    }

    private func publish() {
        chats = store.chats
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.changed() }
    }

    private func lost(_ connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        subscription = nil
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
typealias AgentRecentsFeed = ChatsFeed
