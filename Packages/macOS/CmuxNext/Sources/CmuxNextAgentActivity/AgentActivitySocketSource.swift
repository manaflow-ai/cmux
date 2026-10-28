public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups
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
    /// Follows the helper's socket and credentials (a restart changes them); a service
    /// observation, since it reconnects whether or not the pane shows.
    private var observation: ServiceObservation<Configuration?>?
    private var generation = 0
    private var sink: (@MainActor (AgentActivityUpdate) -> Void)?
    private var subscription: AgentActivityLineConnection?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    /// One backoff wait after a lost connection, or before the next look for a missing socket folder.
    /// `background`: nobody waits on it; the pane shows "not started" or "unreachable" meanwhile.
    private let reconnect: MainDeadline
    /// Where a read timeline lands: one `visible` task (the pane shows it; no input of the person waits on it).
    private let mainWork: MainWorkScheduler
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30))
    private var followed: Set<String> = []
    private var lastSeq: [String: UInt64] = [:]
    private var fetching: Set<String> = []

    /// - Parameters:
    ///   - configuration: The socket and its auth tokens.
    ///   - deadlines: The app's one deadline scheduler (the reconnect backoff).
    public convenience init(configuration: Configuration, deadlines: MainDeadlineScheduler) {
        self.init(configuration: { configuration }, deadlines: deadlines)
    }

    /// Reads the helper's current socket and credentials, including after a restart.
    ///
    /// - Parameters:
    ///   - configuration: The helper's socket and auth tokens now; nil while it has none.
    ///   - deadlines: The app's one deadline scheduler (the reconnect backoff).
    public convenience init(configuration: @escaping @MainActor () -> Configuration?, deadlines: MainDeadlineScheduler) {
        self.init(configuration: configuration, deadlines: deadlines, send: { configuration, method, args in
            try await CuaSocketClient(configuration: configuration).send(method, args)
        })
    }

    init(configuration: @escaping @MainActor () -> Configuration?, deadlines: MainDeadlineScheduler,
         send: @escaping @MainActor (Configuration, String, [String: Any]) async throws -> [String: Any]) {
        readConfiguration = configuration
        self.configuration = configuration()
        self.send = send
        mainWork = deadlines.work
        reconnect = MainDeadline(owner: "AgentActivitySocketSource.reconnect", workClass: .background, scheduler: deadlines)
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            reconnect.cancel()
            subscription?.cancel()
            directoryWatch?.cancel()
        }
    }

    public func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) {
        stop()
        self.sink = sink
        configuration = readConfiguration()
        connect()
        // `background`: a new socket or token reconnects; nobody's input waits on it. Its first
        // apply is the value just read, which changes nothing.
        observation = ServiceObservation(.background, owner: "AgentActivitySocketSource.configuration",
                                         on: mainWork, read: readConfiguration) { [weak self] configuration in
            self?.update(configuration)
        }
    }

    /// Ends the subscription, its reconnects and the socket folder's watch, and discards work
    /// from its old credentials: the page closed or was discarded. Its pending drain finds no
    /// subscription and starts no reconnect.
    public func stop() {
        generation &+= 1
        observation?.cancel()
        observation = nil
        disconnect()
        sink = nil
        followed.removeAll()
    }

    private func disconnect() {
        reconnect.cancel()
        let connection = subscription
        subscription = nil
        connection?.cancel()
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
        guard let reply = try? await request("activity_frame", ["blob": frame.blob, "size": "thumb"]),
              let base64 = reply["data_base64"] as? String, let data = Data(base64Encoded: base64) else { return nil }
        return blockingNSImage(data)
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
        guard let reply = try? JSONSerialization.blockingJSONObject(with: line) as? [String: Any] else { return }
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
        reconnect.schedule(after: backoff.next()) { [weak self] in self?.connect() }
    }

    /// Waits for the socket's directory to change (the host creates the
    /// socket there), then connects. Without the directory, retries with Backoff.
    private func watchForSocket() {
        guard directoryWatch == nil, let config = configuration else { return }
        let directory = (config.socketPath as NSString).deletingLastPathComponent
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            reconnect.schedule(after: backoff.next()) { [weak self] in self?.connect() }
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
        let mainWork = mainWork, current = generation
        // The request's socket I/O runs on its connection's queue; the events land as one posted task.
        Task { @concurrent [weak self] in
            let events = await self?.readTimeline(session, generation: current)
            await mainWork.apply(.visible, owner: "AgentActivitySocketSource.timeline") { [weak self] () -> Void in
                self?.timelineRead(session, events, generation: current)
            }
        }
    }

    /// One `activity_timeline` page of `session` after the last event read; nil when the host did not
    /// answer or the credentials changed since `generation`.
    private func readTimeline(_ session: String, generation current: Int) async -> [AgentActivityEvent]? {
        guard current == generation else { return nil }
        var args: [String: Any] = ["id": session, "limit": 2000]
        if let last = lastSeq[session] { args["after_seq"] = last }
        guard let page = try? await request("activity_timeline", args) else { return nil }
        return AgentActivityWire.events(page)
    }

    private func timelineRead(_ session: String, _ events: [AgentActivityEvent]?, generation current: Int) {
        // A read from older credentials is dropped; the change already cleared `fetching` and refetched.
        guard current == generation else { return }
        fetching.remove(session)
        guard let events else { return }
        if let last = events.last?.seq { lastSeq[session] = last }
        if !events.isEmpty { sink?(.events(session: session, events)) }
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
