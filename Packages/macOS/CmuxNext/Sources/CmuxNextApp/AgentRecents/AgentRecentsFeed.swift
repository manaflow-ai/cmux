import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import os

/// The local acpmux daemon's chats for the sidebar's Recents: one long-lived
/// `_acpmux/watch` connection whose `_acpmux/session_changed` pushes keep the
/// list current, so nothing polls. It connects when the first window shows
/// Recents. When the socket is absent it waits for a directory change on the
/// socket's path; a lost connection reconnects with `Backoff`.
@MainActor
final class AgentRecentsFeed {
    /// The most chats Recents shows.
    static let limit = 8

    private(set) var chats: [AcpmuxRecentChat] = []
    private let socket: String
    private var recents = AcpmuxRecentChats()
    private var observers: [(owner: () -> AnyObject?, changed: @MainActor () -> Void)] = []
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-recents")

    init(socketPath: String) {
        socket = socketPath
    }

    isolated deinit {
        reconnect?.cancel()
        subscription?.cancel()
        directoryWatch?.cancel()
    }

    /// Calls `changed` after each change while `owner` lives; the first
    /// observer starts the watch.
    func observe(_ owner: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        observers.append(({ [weak owner] in owner }, changed))
        if subscription == nil, directoryWatch == nil, reconnect == nil { connect() }
    }

    // MARK: Watch

    private func connect() {
        reconnect = nil
        guard FileManager.default.fileExists(atPath: socket) else { return watchForSocket() }
        directoryWatch?.cancel()
        directoryWatch = nil
        watchedDirectory = nil
        logger.info("agent recents: watching \(self.socket, privacy: .public)")
        let connection = AgentActivityLineConnection(path: socket)
        subscription = connection
        connection.start(send: Self.watchRequest,
                         onLine: { [weak self] line in Task { @MainActor in self?.handle(line) } },
                         onClose: { [weak self] in Task { @MainActor in self?.lost(connection) } })
    }

    /// `initialize`, then `_acpmux/watch` (id 2), one JSON object per line.
    static let watchRequest: Data = {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-sidebar", "version": "1"], "clientCapabilities": [:]],
        ]
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": ["enabled": true]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            payload.append(0x0A)
        }
        return payload
    }()

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if (message["id"] as? NSNumber)?.intValue == 2, let result = message["result"] as? [String: Any] {
            backoff.reset()
            recents.reset(result)
            logger.info("agent recents: \((result["sessions"] as? [Any])?.count ?? 0, privacy: .public) sessions")
        } else if message["method"] as? String == "_acpmux/session_changed", let params = message["params"] as? [String: Any] {
            recents.apply(changed: params)
        } else {
            return
        }
        let next = recents.newest(Self.limit)
        guard next != chats else { return }
        chats = next
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.changed() }
    }

    private func lost(_ connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        subscription = nil
        logger.info("agent recents: watch closed")
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "agent-recents.reconnect") } catch { return }
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
        logger.info("agent recents: waiting for the socket in \(directory, privacy: .public)")
        directoryWatch?.cancel()
        directoryWatch = nil
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        source.setCancelHandler { close(fd) }
        directoryWatch = source
        watchedDirectory = directory
        source.resume()
    }
}
