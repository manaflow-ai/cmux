import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation

/// The device-wide acpmux chat index for sidebar and palette clients.
@MainActor
final class ChatsFeed {
    /// The mirror (a copy-on-write value: taking it is O(1), so readers that
    /// need every chat take it off the main actor).
    private(set) var store = AcpmuxChatsStore()
    /// Every chat, newest first. O(n) per read: per-change readers use
    /// `chat(id:)` and `newest(_:)`; a publish no longer builds this list.
    var chats: [AcpmuxChat] { store.chats }
    private(set) var isEnabled = true
    private(set) var isReady = false
    private let socket: String
    private var observers: [(owner: () -> AnyObject?, changed: @MainActor () -> Void)] = []
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var reconnect: Task<Void, Never>?
    private var requestID = 2
    /// The seq of the last index change in the mirror (acpmux numbers every change; the page
    /// names the last one it holds). Nil from a daemon that does not number them.
    private var seq: UInt64?
    /// A page request (the watch's own, or a list again) has no answer yet.
    private var pageInFlight = false
    /// Another list was asked for while one was in flight: send it when that page lands.
    private var listAgain = false
    /// Changes that arrived while a page was in flight: the daemon may send a change numbered
    /// past the page before the page's line (it serializes megabytes after reading the index).
    /// They are replayed on top of the page; those it holds are dropped by their seq.
    private var early: [(change: AcpmuxChatsStore.Change, seq: UInt64?)] = []
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))

    init(socketPath: String) { socket = socketPath }

    /// One chat by key, O(1).
    func chat(id: String) -> AcpmuxChat? { store.chat(id: id) }

    /// The newest `limit` chats, O(limit).
    func newest(_ limit: Int) -> [AcpmuxChat] { store.newest(limit) }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
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
        seq = nil // a restarted daemon numbers from 0 again
        pageInFlight = true
        listAgain = false
        early = []
        // Lines decode on the socket queue (the first page is megabytes) and reach the main
        // actor as one batch at a time: a burst of changes is one publish, never a Task per line.
        connection.start(send: Self.watchRequest(limit: 5000), decode: Message.init(line:)) { [weak self, weak connection] drain in
            if let connection { self?.apply(drain, from: connection) }
        }
    }

    /// One decoded line of the watch.
    nonisolated enum Message: Sendable {
        /// A page response: the whole mirror, decoded off the main actor in acpmux's order.
        case page(store: AcpmuxChatsStore, ready: Bool, enabled: Bool, seq: UInt64?)
        /// One index change and its seq (nil for activity, which is not an index change).
        case change(AcpmuxChatsStore.Change, seq: UInt64?)
        case lagged

        init?(line: Data) {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            if let id = (message["id"] as? NSNumber)?.intValue, id == 2 || id >= 3,
               let result = message["result"] as? [String: Any] {
                var store = AcpmuxChatsStore()
                store.reset(result)
                self = .page(store: store, ready: result["ready"] as? Bool ?? false, enabled: result["enabled"] as? Bool ?? true,
                             seq: (result["seq"] as? NSNumber)?.uint64Value)
                return
            }
            switch message["method"] as? String {
            case "_acpmux/chat_changed":
                let params = message["params"] as? [String: Any]
                guard let change = params.flatMap(AcpmuxChatsStore.change(from:)) else { return nil }
                self = .change(change, seq: (params?["seq"] as? NSNumber)?.uint64Value)
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
        let started = ContinuousClock.now
        defer { DebugTimings.chatsFeedApplied(lines: drain.values.count, ContinuousClock.now - started) }
        var changed = false
        var lagged = false
        for message in drain.values {
            switch message {
            case .page(let page, let ready, let enabled, let pageSeq):
                store = page
                seq = pageSeq
                isReady = ready
                isEnabled = enabled
                backoff.reset()
                pageInFlight = false
                lagged = listAgain
                listAgain = false
                let replay = early
                early = []
                for item in replay where !applyChange(item.change, seq: item.seq) { lagged = true }
                changed = true
            case .change(let change, let changeSeq):
                if pageInFlight {
                    if early.count < Self.earlyLimit { early.append((change, changeSeq)) } else { listAgain = true }
                    continue
                }
                if !applyChange(change, seq: changeSeq) { lagged = true }
                changed = true
            case .lagged:
                lagged = true
            }
        }
        // Dropped lines (a full batch) leave the mirror incomplete, like a lag: fetch a fresh page.
        if lagged || drain.overflowed, !drain.closed { requestList() }
        if changed { publish() }
        if drain.closed { lost(connection) }
    }

    private static let earlyLimit = 4096

    /// Applies one change unless the mirror already holds it (its seq is at or below the
    /// mirror's). False on a jump in seq: a change was lost and the caller lists again.
    private func applyChange(_ change: AcpmuxChatsStore.Change, seq changeSeq: UInt64?) -> Bool {
        var contiguous = true
        if let changeSeq {
            if let last = seq {
                if changeSeq <= last { return true }
                contiguous = changeSeq == last + 1
            }
            seq = changeSeq
        }
        store.apply(change)
        return contiguous
    }

    /// One list at a time: a request while a page is in flight is sent when it lands.
    private func requestList() {
        guard let subscription else { return }
        guard !pageInFlight else {
            listAgain = true
            return
        }
        pageInFlight = true
        requestID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": "_acpmux/chats",
                                       "params": ["limit": 5000]]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        var line = data
        line.append(0x0A)
        subscription.send(line)
    }

    private func publish() {
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
