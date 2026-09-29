public import CmuxNextSettings
import Foundation
import Synchronization

/// Answers control-socket methods. Transport and authorization live in
/// `ControlSocketServer`; this type is request -> response, so tests drive
/// it without a socket.
///
/// Every method runs on a lane (``ControlMethod/Lane``): read-only methods
/// answer off the main actor from the published ``ControlSnapshot``;
/// mutating methods (`action.run`, compat mutations) go through the bounded
/// ``MainActorWorkQueue``; the rest run off-main under the request deadline.
/// No request can wait past its deadline (default 2 s).
public final class ControlRouter: Sendable {
    public struct Configuration: Sendable {
        /// Deadline for every request that is not answered from the snapshot.
        public var requestDeadline: Duration
        public var queueLimits: MainActorWorkQueue.Limits

        public init(requestDeadline: Duration = .seconds(2), queueLimits: MainActorWorkQueue.Limits = MainActorWorkQueue.Limits()) {
            self.requestDeadline = requestDeadline
            self.queueLimits = queueLimits
        }
    }

    /// Wire protocol version reported by `system.ping` and `system.identify`.
    public static let protocolVersion = 1

    public let identity: ControlIdentity
    public let configuration: Configuration
    public let snapshots = ControlSnapshotStore()
    public let workQueue: MainActorWorkQueue
    let executor: any ControlActionExecutor
    let settings: (any ControlSettingsStore)?
    private let state = Mutex(State())

    struct State {
        var methods: [String: ControlMethod] = [:]
        var order: [String] = []
        var socketPath: String?
        var accessMode: String?
        var watchdog: MainThreadWatchdog?
    }

    public init(
        identity: ControlIdentity,
        executor: any ControlActionExecutor,
        settings: (any ControlSettingsStore)? = nil,
        configuration: Configuration = Configuration(),
        frameSource: any ControlFrameSource = MainQueueFrameSource()
    ) {
        self.identity = identity
        self.executor = executor
        self.settings = settings
        self.configuration = configuration
        self.workQueue = MainActorWorkQueue(limits: configuration.queueLimits, frameSource: frameSource)
        register(builtinMethods())
    }

    // MARK: - Registration

    /// Adds methods. A later registration with the same name replaces the
    /// earlier one (the App or compat layer may refine a built-in).
    public func register(_ methods: [ControlMethod]) {
        state.withLock { state in
            for method in methods {
                if state.methods.updateValue(method, forKey: method.name) == nil { state.order.append(method.name) }
            }
        }
    }

    /// Registered method names in registration order.
    public var methodNames: [String] { state.withLock { $0.order } }

    public func method(named name: String) -> ControlMethod? { state.withLock { $0.methods[name] } }

    // MARK: - Snapshot

    public var catalog: ControlCatalog { snapshots.current.catalog }

    public func updateCatalog(_ catalog: ControlCatalog) {
        snapshots.publish { $0.catalog = catalog }
    }

    public func updateContextMask(_ mask: UInt32) {
        snapshots.publish { $0.catalog.contextMask = mask }
    }

    func setTransportInfo(socketPath: String, accessMode: String) {
        state.withLock {
            $0.socketPath = socketPath
            $0.accessMode = accessMode
        }
    }

    var transportInfo: (socketPath: String?, accessMode: String?) { state.withLock { ($0.socketPath, $0.accessMode) } }

    /// The watchdog `debug.hangs` reports. The App installs it at launch.
    public func attach(watchdog: MainThreadWatchdog?) {
        state.withLock { $0.watchdog = watchdog }
    }

    var watchdog: MainThreadWatchdog? { state.withLock { $0.watchdog } }

    // MARK: - Lines

    /// Decodes one line and returns the response line (without newline).
    public func response(forLine line: String, connection: ControlConnectionID = .inProcess) async -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else {
            // v1 plain-text commands: only the liveness probe is kept.
            switch trimmed.split(separator: " ", maxSplits: 1).first.map({ $0.lowercased() }) {
            case "ping": return "PONG"
            default: return "ERROR: Unknown command '\(trimmed.split(separator: " ").first ?? "")'. cmux-next speaks v2 JSON requests only."
            }
        }
        let request: ControlRequest
        switch ControlWire.decode(trimmed) {
        case .success(let decoded): request = decoded
        case .failure(let error): return ControlWire.encode(id: nil, error: error)
        }
        return ControlWire.encode(id: request.id, result: await handle(request, connection: connection))
    }

    static func decode(_ line: String) -> Result<ControlRequest, ControlError> { ControlWire.decode(line) }

    static func encode(id: JSONValue?, result: Result<JSONValue, ControlError>) -> String {
        ControlWire.encode(id: id, result: result)
    }

    static func encode(id: JSONValue?, error: ControlError) -> String { ControlWire.encode(id: id, error: error) }

    // MARK: - Dispatch

    public func handle(_ request: ControlRequest, connection: ControlConnectionID = .inProcess) async -> Result<JSONValue, ControlError> {
        guard let method = method(named: request.method) else {
            return .failure(ControlError(code: "method_not_found", message: "Unknown method \(request.method)",
                                         data: ["method": .string(request.method)]))
        }
        let call = ControlCall(request: request, snapshot: snapshots.current, connection: connection,
                               deadline: .now + configuration.requestDeadline)
        do {
            return .success(try await Self.run(method, call, queue: workQueue))
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(code: "internal_error", message: String(describing: error)))
        }
    }

    static func run(_ method: ControlMethod, _ call: ControlCall, queue: MainActorWorkQueue) async throws -> JSONValue {
        switch method.body {
        case .snapshot(let body):
            return try body(call)
        case .async(let body):
            return try await ControlDeadline.run(method: call.method, deadline: call.deadline) { try await body(call) }
        case .mainActor(let body):
            let reply = try await queue.run(connection: call.connection, method: call.method, deadline: call.deadline) {
                try body(call)
            }
            switch reply {
            case .value(let value):
                return value
            case .followUp(let work):
                return try await ControlDeadline.run(method: call.method, deadline: call.deadline, work)
            }
        }
    }
}
