public import AppKit
import CmuxNextCompat
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

        /// The socket override and its auth tokens. CMUX_NEXT_ names, because
        /// the app strips every other inherited CMUX* variable at launch
        /// (LaunchIdentity); a tagged app and its tests set these to reach a
        /// tag-scoped cmux-cua socket, never the shared default path.
        public static let socketEnvironmentKey = "CMUX_NEXT_CUA_SOCKET"
        public static let authTokenEnvironmentKey = "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"
        public static let hostAuthTokenEnvironmentKey = "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN"

        /// The default socket with the auth tokens from the environment.
        public static func standard(machineName: String,
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: String = NSHomeDirectory()) -> Configuration {
            Configuration(socketPath: defaultSocketPath(environment: environment, home: home),
                          authToken: environment[authTokenEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 },
                          hostAuthToken: environment[hostAuthTokenEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 },
                          machineName: machineName)
        }

        /// The standalone daemon's default socket (cmux-cua `default_socket_path`).
        public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                             home: String = NSHomeDirectory()) -> String {
            if let path = environment[socketEnvironmentKey], !path.isEmpty { return path }
            return home + "/Library/Caches/cmux-cua/cmux-cua.sock"
        }
    }

    private let config: Configuration
    private var sink: (@MainActor (AgentActivityUpdate) -> Void)?
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var reconnect: Task<Void, Never>?
    /// The read of the socket's path in flight (``SocketPathProbe``, off the main actor).
    private var probe: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private var followed: Set<String> = []
    private var lastSeq: [String: UInt64] = [:]
    private var fetching: Set<String> = []

    public init(configuration: Configuration) {
        config = configuration
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            probe?.cancel()
            reconnect?.cancel()
            subscription?.cancel()
            directoryWatch?.cancel()
        }
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

    /// Reads the socket's path off the main actor (a stat can hang on a sleeping volume), then
    /// subscribes, or shows "not started" and waits for the socket. A newer read replaces one in
    /// flight: the folder event that started it may have come after the older read's stat.
    private func connect() {
        probe?.cancel()
        let socketPath = config.socketPath
        let watching = directoryWatch == nil ? nil : (socketPath as NSString).deletingLastPathComponent
        probe = Task { [weak self] in
            let found = await SocketPathProbe.read(socket: socketPath, folder: .parent, watching: watching)
            guard let self, !Task.isCancelled else { return found.close() }
            probe = nil
            switch found {
            case .present:
                subscribe()
            case .absent(_, let descriptor):
                sink?(.connection(machine: config.machine, .notStarted))
                watchForSocket(descriptor: descriptor)
            }
        }
    }

    private func subscribe() {
        directoryWatch?.cancel()
        directoryWatch = nil
        let connection = AgentActivityLineConnection(path: config.socketPath,
                                                     acceptsServer: CuaHelperIdentity.isHelperServer)
        subscription = connection
        connection.start(
            send: AgentActivityWire.requestLine(method: "activity_subscribe", args: ["sessions": true, "events_for": []],
                                                authToken: config.authToken, hostAuthToken: config.hostAuthToken),
            // One main-actor batch at a time, never a Task per line (MainActorLineBatch).
            decode: { $0 }) { [weak self, weak connection] drain in
                guard let self, let connection, subscription === connection else { return }
                for line in drain.values { handle(line) }
                if drain.overflowed, !drain.closed { connection.cancel() }
                if drain.overflowed || drain.closed { lost(connection) }
            }
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
        reconnect?.cancel()
        let socketPath = config.socketPath, machine = config.machine
        reconnect = Task { [weak self] in
            // The socket file still there: its server stopped answering; gone: it was not started.
            let present = await Self.socketExists(socketPath)
            guard !Task.isCancelled, var backoff = self?.backoff else { return }
            self?.sink?(.connection(machine: machine, present ? .unreachable : .notStarted))
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "agent-activity.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }

    /// Whether a file is at the socket's path: a stat, off the main actor.
    @concurrent nonisolated private static func socketExists(_ path: String) async -> Bool {
        FileManager.checked.fileExists(atPath: path)
    }

    /// Waits for the socket's directory to change (the host creates the
    /// socket there), then connects. Without the directory, retries with Backoff.
    /// The directory was opened off the main actor as `descriptor` (nil: it could not be, or it
    /// is watched already).
    private func watchForSocket(descriptor: Int32?) {
        guard directoryWatch == nil else {
            if let descriptor { close(descriptor) }
            return
        }
        guard let fd = descriptor else {
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
            MainActor.assumeIsolated { self?.connect() } // main-proof: dispatch source on queue: .main
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
        try await CuaSocketClient(configuration: config).send(method, args)
    }
}

public enum AgentActivitySourceError: Error, Equatable {
    case malformed
    case refused(String)
    case timedOut
    case closed
}
