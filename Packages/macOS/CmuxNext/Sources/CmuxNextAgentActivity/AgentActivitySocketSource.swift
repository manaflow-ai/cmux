public import AppKit
import CmuxNextWakeups
import Foundation
import Network

/// `AgentActivitySource` over the local CUA host socket (computer-use.md
/// section 6a). One long-lived `activity_subscribe` connection pushes session
/// lists and event notices; timelines, frames and user operations are one-shot
/// requests with a deadline. Everything blocking runs on a private queue; the
/// model only sees main-actor pushes. When the socket is absent the pane shows
/// "not started" and the source waits for the socket directory to change
/// (an event, not a poll); a lost connection reconnects with `Backoff`.
@MainActor
public final class AgentActivitySocketSource: AgentActivitySource {
    public struct Configuration: Sendable {
        public var socketPath: String
        public var authToken: String?
        public var hostAuthToken: String?
        public var machine: String
        public var machineName: String

        public init(socketPath: String, authToken: String? = nil, hostAuthToken: String? = nil,
                    machine: String = AgentActivityModel.localMachine, machineName: String) {
            self.socketPath = socketPath
            self.authToken = authToken
            self.hostAuthToken = hostAuthToken
            self.machine = machine
            self.machineName = machineName
        }

        /// The standalone daemon's default socket (cmux-cua `default_socket_path`).
        public static func defaultSocketPath() -> String {
            if let path = ProcessInfo.processInfo.environment["CMUX_CUA_SOCKET"], !path.isEmpty { return path }
            return NSHomeDirectory() + "/Library/Caches/cmux-cua/cmux-cua.sock"
        }
    }

    private let config: Configuration
    private var sink: (@MainActor (AgentActivityUpdate) -> Void)?
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private var followed: Set<String> = []
    private var lastSeq: [String: UInt64] = [:]
    private var fetching: Set<String> = []

    public init(configuration: Configuration) {
        config = configuration
    }

    isolated deinit {
        reconnect?.cancel()
        subscription?.cancel()
        directoryWatch?.cancel()
    }

    public func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) {
        self.sink = sink
        connect()
    }

    public func follow(session: String, _ on: Bool) {
        if on {
            followed.insert(session)
            fetchTimeline(session)
        } else {
            followed.remove(session)
        }
    }

    public func image(for frame: AgentActivityFrameRef) async -> NSImage? {
        guard let reply = try? await request("activity_frame", ["blob": frame.blob, "size": "thumb"]),
              let base64 = reply["data_base64"] as? String, let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }

    public func perform(_ op: AgentActivityUserOp) async throws {
        guard let (method, args) = AgentActivityWire.op(op) else { return }
        _ = try await request(method, args)
    }

    // MARK: Subscription

    private func connect() {
        guard FileManager.default.fileExists(atPath: config.socketPath) else {
            sink?(.connection(machine: config.machine, .notStarted))
            watchForSocket()
            return
        }
        directoryWatch?.cancel()
        directoryWatch = nil
        let connection = AgentActivityLineConnection(path: config.socketPath)
        subscription = connection
        connection.start(
            send: AgentActivityWire.requestLine(method: "activity_subscribe", args: ["sessions": true, "events_for": []],
                                                authToken: config.authToken, hostAuthToken: config.hostAuthToken),
            onLine: { [weak self] line in Task { @MainActor in self?.handle(line) } },
            onClose: { [weak self] in Task { @MainActor in self?.lost(connection) } })
    }

    private func handle(_ line: Data) {
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] else {
            sink?(.connection(machine: config.machine, .unreachable))
            return
        }
        backoff.reset()
        switch result["type"] as? String {
        case "sessions":
            let rows = result["sessions"] as? [[String: Any]] ?? []
            let sessions = rows.compactMap { AgentActivityWire.session($0, machine: config.machine, machineName: config.machineName) }
            sink?(.connection(machine: config.machine, .connected))
            sink?(.sessions(machine: config.machine, sessions))
        case "events":
            if let session = result["session"] as? String, followed.contains(session) { fetchTimeline(session) }
        default:
            break
        }
    }

    private func lost(_ connection: AgentActivityLineConnection) {
        guard subscription === connection else { return }
        subscription = nil
        sink?(.connection(machine: config.machine, FileManager.default.fileExists(atPath: config.socketPath) ? .unreachable : .notStarted))
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "agent-activity.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }

    /// Waits for the socket's directory to change (the host creates the
    /// socket there), then connects. Without the directory, retries with Backoff.
    private func watchForSocket() {
        guard directoryWatch == nil else { return }
        let directory = (config.socketPath as NSString).deletingLastPathComponent
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            reconnect?.cancel()
            reconnect = Task { [weak self] in
                guard var backoff = self?.backoff else { return }
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                do { try await backoff.wait(owner: "agent-activity.socket-dir") } catch { return }
                self?.backoff = backoff
                self?.connect()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        source.setCancelHandler { close(fd) }
        directoryWatch = source
        source.resume()
    }

    // MARK: Requests

    private func fetchTimeline(_ session: String) {
        guard !fetching.contains(session) else { return }
        fetching.insert(session)
        Task { [weak self] in
            guard let self else { return }
            var args: [String: Any] = ["id": session, "limit": 2000]
            if let last = lastSeq[session] { args["after_seq"] = last }
            let page = try? await request("activity_timeline", args)
            fetching.remove(session)
            guard let page else { return }
            let events = AgentActivityWire.events(page)
            if let last = events.last?.seq { lastSeq[session] = last }
            if !events.isEmpty { sink?(.events(session: session, events)) }
        }
    }

    private func request(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        let line = AgentActivityWire.requestLine(method: method, args: args, authToken: config.authToken,
                                                 hostAuthToken: config.hostAuthToken)
        let data = try await AgentActivityLineConnection.oneShot(path: config.socketPath, send: line, deadline: .seconds(5))
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentActivitySourceError.malformed
        }
        guard reply["ok"] as? Bool == true else {
            throw AgentActivitySourceError.refused(reply["error"] as? String ?? "error")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }
}

public enum AgentActivitySourceError: Error, Equatable {
    case malformed
    case refused(String)
    case timedOut
    case closed
}
