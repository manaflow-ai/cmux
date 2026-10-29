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
    public struct Configuration: Sendable, Equatable {
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

    private var configuration: Configuration?
    private let readConfiguration: @MainActor () -> Configuration?
    private let send: @MainActor (Configuration, String, [String: Any]) async throws -> [String: Any]
    private var observation: Task<Void, Never>?
    private var generation = 0
    private var sink: (@MainActor (AgentActivityUpdate) -> Void)?
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private var followed: Set<String> = []
    private var lastSeq: [String: UInt64] = [:]
    private var fetching: Set<String> = []

    public convenience init(configuration: Configuration) {
        self.init(configuration: { configuration })
    }

    /// Reads the helper's current socket and credentials, including after a restart.
    public convenience init(configuration: @escaping @MainActor () -> Configuration?) {
        self.init(configuration: configuration, send: { configuration, method, args in
            try await CuaSocketClient(configuration: configuration).send(method, args)
        })
    }

    init(configuration: @escaping @MainActor () -> Configuration?,
         send: @escaping @MainActor (Configuration, String, [String: Any]) async throws -> [String: Any]) {
        readConfiguration = configuration
        self.configuration = configuration()
        self.send = send
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            reconnect?.cancel()
            subscription?.cancel()
            directoryWatch?.cancel()
        }
    }

    public func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) {
        stop()
        self.sink = sink
        configuration = readConfiguration()
        connect()
        let read = readConfiguration
        observation = Task { [weak self] in
            for await configuration in ObservationStream({ read() }) {
                guard !Task.isCancelled else { return }
                self?.update(configuration)
            }
        }
    }

    /// Ends the subscription and discards work from its old credentials.
    public func stop() {
        generation &+= 1
        observation?.cancel()
        observation = nil
        disconnect()
        sink = nil
    }

    private func disconnect() {
        reconnect?.cancel()
        reconnect = nil
        subscription?.cancel()
        subscription = nil
        directoryWatch?.cancel()
        directoryWatch = nil
    }

    private func update(_ next: Configuration?) {
        guard next != configuration else { return }
        generation &+= 1
        disconnect()
        let machine = configuration?.machine ?? next?.machine ?? AgentActivityModel.localMachine
        configuration = next
        lastSeq.removeAll()
        fetching.removeAll()
        backoff.reset()
        sink?(.sessions(machine: machine, []))
        guard next != nil else {
            sink?(.connection(machine: machine, .notStarted))
            return
        }
        connect()
        for session in followed { fetchTimeline(session) }
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
        guard let data = await self.frame(frame, size: .thumb, session: nil),
              let bytes = Data(base64Encoded: data.base64) else { return nil }
        return NSImage(data: bytes)
    }

    /// The host's bytes for `frame`. A `full` request the host cannot answer
    /// (retention dropped it, or an older host) falls back to the thumbnail.
    public func frame(_ frame: AgentActivityFrameRef, size: AgentActivityFrameSize,
                      session: String?) async -> AgentActivityFrameData? {
        if size == .full,
           let reply = try? await request("activity_frame", AgentActivityWire.frameArgs(blob: frame.blob, size: .full, session: session)),
           let data = AgentActivityWire.frameData(reply) {
            return data
        }
        guard let reply = try? await request("activity_frame", AgentActivityWire.frameArgs(blob: frame.blob, size: .thumb, session: session))
        else { return nil }
        return AgentActivityWire.frameData(reply)
    }

    public func perform(_ op: AgentActivityUserOp) async throws {
        guard let (method, args) = AgentActivityWire.op(op) else {
            throw AgentActivitySourceError.unsupported(op)
        }
        _ = try await request(method, args)
    }

    // MARK: Subscription

    private func connect() {
        guard subscription == nil else { return }
        guard let config = configuration else {
            sink?(.connection(machine: AgentActivityModel.localMachine, .notStarted))
            return
        }
        guard FileManager.default.fileExists(atPath: config.socketPath) else {
            sink?(.connection(machine: config.machine, .notStarted))
            watchForSocket()
            return
        }
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
        guard let config = configuration else { return }
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
        guard subscription === connection, let config = configuration else { return }
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
        guard directoryWatch == nil, let config = configuration else { return }
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
        let current = generation
        Task { [weak self] in
            guard let self, current == generation else { return }
            var args: [String: Any] = ["id": session, "limit": 2000]
            if let last = lastSeq[session] { args["after_seq"] = last }
            let page = try? await request("activity_timeline", args)
            guard current == generation else { return }
            fetching.remove(session)
            guard let page else { return }
            let events = AgentActivityWire.events(page)
            if let last = events.last?.seq { lastSeq[session] = last }
            if !events.isEmpty { sink?(.events(session: session, events)) }
        }
    }

    private func request(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        update(readConfiguration())
        guard let configuration else { throw AgentActivitySourceError.closed }
        let current = generation
        let reply = try await send(configuration, method, args)
        guard current == generation else { throw AgentActivitySourceError.closed }
        return reply
    }
}

public enum AgentActivitySourceError: Error, Equatable {
    case malformed
    case refused(String)
    case unsupported(AgentActivityUserOp)
    case timedOut
    case closed
}

extension AgentActivitySourceError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .unsupported: AgentActivityStrings.unsupportedOperation
        default: nil
        }
    }

    public var description: String {
        switch self {
        case .unsupported: AgentActivityStrings.unsupportedOperation
        case .refused(let reason): reason
        case .malformed: "malformed"
        case .timedOut: "timedOut"
        case .closed: "closed"
        }
    }
}
