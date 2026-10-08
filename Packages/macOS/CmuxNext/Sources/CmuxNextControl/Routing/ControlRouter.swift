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
/// No request can wait past its deadline (default 2 s; a request that
/// starts a terminal gets ``Configuration/terminalStartDeadline``).
public final class ControlRouter: Sendable {
    public struct Configuration: Sendable {
        /// Deadline for every request that is not answered from the snapshot.
        public var requestDeadline: Duration
        /// Deadline for a request that waits for a terminal to start
        /// (``ControlMethod/Deadline/terminalStart``).
        public var terminalStartDeadline: Duration
        public var queueLimits: MainActorWorkQueue.Limits
        /// Whether `debug.*` methods may be registered: only in DEBUG builds
        /// (``ControlRouter/debugMethodsAllowed``). A release router drops
        /// every `debug.*` registration, so no release build serves one.
        public var allowsDebugMethods: Bool

        public init(requestDeadline: Duration = .seconds(2), terminalStartDeadline: Duration = ControlRouter.terminalStartDeadline,
                    queueLimits: MainActorWorkQueue.Limits = MainActorWorkQueue.Limits(),
                    allowsDebugMethods: Bool = ControlRouter.debugMethodsAllowed) {
            self.requestDeadline = requestDeadline
            self.terminalStartDeadline = terminalStartDeadline
            self.queueLimits = queueLimits
            self.allowsDebugMethods = allowsDebugMethods
        }
    }

    /// True in DEBUG builds only: release builds serve no `debug.*` method.
    public static var debugMethodsAllowed: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// A `debug.*` method: diagnostics and automation for tagged DEV builds.
    public static func isDebugMethod(_ name: String) -> Bool { name.hasPrefix("debug.") }

    /// Default deadline for a request that starts a terminal: the daemon's
    /// own terminal start deadline (`DaemonConnection.defaultSpawnTimeout`)
    /// plus 1 s for the work queue and the compat layer's tree diff, so the
    /// daemon command answers or fails before the request does.
    public static let terminalStartDeadline: Duration = TerminalStartDeadline.request

    /// Wire protocol version reported by `system.ping` and `system.identify`.
    public static let protocolVersion = 1

    public let identity: ControlIdentity
    public let configuration: Configuration
    public let snapshots = ControlSnapshotStore()
    /// Events for `events.stream` (ControlRouter+EventStream).
    public let events = ControlEventBus()
    public let workQueue: MainActorWorkQueue
    /// Recent `action.run` results by idempotency key.
    let idempotency = ControlIdempotencyCache()
    let executor: any ControlActionExecutor
    let settings: (any ControlSettingsStore)?
    /// Writes schema settings through the settings owner; nil in tests
    /// that only give a file (schema values are still validated).
    let settingsWriter: (any ControlSettingsWriter)?
    private let state = Mutex(State())

    struct State {
        var methods: [String: ControlMethod] = [:]
        var order: [String] = []
        var socketPath: String?
        var accessMode: String?
        var watchdog: MainThreadWatchdog?
        /// Answers v1 plain-text lines other than `ping` (the cmux CLI compat layer).
        var v1Handler: (@Sendable (String) async -> String?)?
        /// Typed error for a method nobody registered (compat: `unsupported in cmux-next: …`).
        var unknownMethod: (@Sendable (String) -> ControlError?)?
        /// Rewrites `action.run` targets the App does not name (compat: `surface:2`, old UUIDs).
        var targetResolver: TargetResolver?
        /// The local daemon's event sequence after a round trip (`after: "sync"`).
        var syncBarrier: (@Sendable () async throws -> UInt64)?
    }

    /// Maps a validated target to the App's model id, or throws a typed
    /// error (`not_found`). Runs off the main actor under the request deadline.
    public typealias TargetResolver = @Sendable (ControlTargetRef, ContinuousClock.Instant) async throws -> ControlTargetRef

    public init(
        identity: ControlIdentity,
        executor: any ControlActionExecutor,
        settings: (any ControlSettingsStore)? = nil,
        settingsWriter: (any ControlSettingsWriter)? = nil,
        configuration: Configuration = Configuration(),
        frameSource: any ControlFrameSource = MainQueueFrameSource()
    ) {
        self.identity = identity
        self.executor = executor
        self.settings = settings
        self.settingsWriter = settingsWriter
        self.configuration = configuration
        self.workQueue = MainActorWorkQueue(limits: configuration.queueLimits, frameSource: frameSource)
        register(builtinMethods())
    }

    // MARK: - Registration

    /// Adds methods. A later registration with the same name replaces the
    /// earlier one (the App or compat layer may refine a built-in). A
    /// `debug.*` method is dropped unless the configuration allows debug
    /// methods (DEBUG builds), whichever code path registers it.
    public func register(_ methods: [ControlMethod]) {
        let allowsDebug = configuration.allowsDebugMethods
        state.withLock { state in
            for method in methods where allowsDebug || !Self.isDebugMethod(method.name) {
                if state.methods.updateValue(method, forKey: method.name) == nil { state.order.append(method.name) }
            }
        }
    }

    /// Installs the v1 plain-text handler; it returns nil for lines it does not know.
    public func registerV1(_ handler: @escaping @Sendable (String) async -> String?) {
        state.withLock { $0.v1Handler = handler }
    }

    /// Installs the error for unregistered methods; nil keeps `method_not_found`.
    public func registerUnknownMethod(_ handler: @escaping @Sendable (String) -> ControlError?) {
        state.withLock { $0.unknownMethod = handler }
    }

    /// Installs the `action.run` target resolver (the compat layer's old refs).
    public func registerTargetResolver(_ resolver: @escaping TargetResolver) {
        state.withLock { $0.targetResolver = resolver }
    }

    var targetResolver: TargetResolver? { state.withLock { $0.targetResolver } }

    /// Installs the `after: "sync"` barrier: a round trip to the local
    /// daemon that returns the event sequence covering every write the
    /// daemon committed before it (the App's `DaemonConnection.eventSequence`).
    public func registerSyncBarrier(_ barrier: @escaping @Sendable () async throws -> UInt64) {
        state.withLock { $0.syncBarrier = barrier }
    }

    var syncBarrier: (@Sendable () async throws -> UInt64)? { state.withLock { $0.syncBarrier } }

    /// Registered method names in registration order.
    public var methodNames: [String] { state.withLock { $0.order } }

    public func method(named name: String) -> ControlMethod? { state.withLock { $0.methods[name] } }

    // MARK: - Snapshot

    public var catalog: ControlCatalog { snapshots.current.catalog }

    /// Publishes `catalog`; when its actions changed, also publishes
    /// `action.catalog.changed` on `events.stream`, so a client that mirrors
    /// the actions (`cmux mcp serve`) re-reads `action.list` instead of
    /// polling it. Context-bit changes (`updateContextMask`) are not changes.
    public func updateCatalog(_ catalog: ControlCatalog) {
        var changed = false
        snapshots.publish { snapshot in
            changed = snapshot.catalog.actions != catalog.actions
            snapshot.catalog = catalog
        }
        guard changed else { return }
        events.publish(name: Self.actionCatalogChangedEvent, category: "action", source: "app",
                       payload: ["count": JSONValue(catalog.actions.count)])
    }

    /// The `events.stream` event name for a changed action registry.
    public static let actionCatalogChangedEvent = "action.catalog.changed"

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
            default:
                if let handler = state.withLock({ $0.v1Handler }) {
                    // Same bound as a v2 request (architecture.md 5a).
                    let reply: String?
                    do {
                        reply = try await ControlDeadline.shared.run(method: "v1 \(trimmed.split(separator: " ").first ?? "")",
                                                              deadline: .now + configuration.requestDeadline) { await handler(trimmed) }
                    } catch let error as ControlError {
                        return "ERROR: \(error.message)"
                    } catch {
                        return "ERROR: \(error)"
                    }
                    if let reply { return reply }
                }
                return "ERROR: Unknown command '\(trimmed.split(separator: " ").first ?? "")'. cmux-next speaks v2 JSON requests only."
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
            if let error = state.withLock({ $0.unknownMethod })?(request.method) { return .failure(error) }
            return .failure(Self.methodNotFound(request.method, appCLIPath: identity.appCLIPath))
        }
        var snapshot = snapshots.current
        let startsTerminal = method.startsTerminal(request, snapshot)
        let limit = method.limitOverride?(request, snapshot) ?? method.fixedLimit ?? (startsTerminal ? configuration.terminalStartDeadline : configuration.requestDeadline)
        let deadline = ContinuousClock.now + limit
        let progress = ControlCallProgress()
        do {
            // Read barrier (state-ownership.md 4.3): answer from a snapshot
            // that covers the caller's earlier writes.
            // `debug.hangs` reads its own `after` (a hang log cursor).
            if request.method != "debug.hangs", let after = request.params["after"], !after.isNull {
                snapshot = try await readBarrier(after, method: request.method, deadline: deadline)
            }
            let call = ControlCall(request: request, snapshot: snapshot, connection: connection,
                                   deadline: deadline, startsTerminal: startsTerminal, progress: progress)
            return .success(try await Self.run(method, call, queue: workQueue))
        } catch let error as ControlError {
            return .failure(error.annotated(progress: progress))
        } catch {
            return .failure(ControlError(code: "internal_error", message: String(describing: error)))
        }
    }

    /// `method_not_found`. This app's own CLI only sends methods the app
    /// has, so an unknown one most often comes from an older `cmux` (the
    /// classic app's CLI, or a cmux-next CLI from an older build) that a
    /// shell found first on `PATH`: with a bundled CLI the message says so
    /// and names it (also as `app_cli_path`). The code stays the same.
    static func methodNotFound(_ method: String, appCLIPath: String?) -> ControlError {
        guard let cli = appCLIPath, !cli.isEmpty else {
            return ControlError(code: "method_not_found",
                                message: ControlStrings.format("control.error.unknownMethod", "Unknown method %@", method),
                                data: ["method": .string(method)])
        }
        return ControlError(
            code: "method_not_found",
            message: ControlStrings.format("control.error.unknownMethodOlderCLI",
                                           "Unknown method %1$@: this cmux CLI is older than this app (or belongs to another cmux app). Use this app's CLI: %2$@",
                                           method, cli),
            data: ["method": .string(method), "app_cli_path": .string(cli)])
    }

    static func run(_ method: ControlMethod, _ call: ControlCall, queue: MainActorWorkQueue) async throws -> JSONValue {
        switch method.body {
        case .snapshot(let body):
            return try body(call)
        case .async(let body):
            if !method.claimsProgress { _ = call.progress.begin() }
            return try await ControlDeadline.shared.run(method: call.method, deadline: call.deadline,
                                                 startsTerminal: call.startsTerminal) { try await body(call) }
        case .mainActor(let body):
            let expired = ControlError.timeout(call.method, after: max(call.deadline - .now, .zero))
            let reply = try await queue.run(connection: call.connection, method: call.method, deadline: call.deadline) {
                // The request may have answered `not_run` already.
                guard call.progress.begin() else { throw expired }
                return try body(call)
            }
            switch reply {
            case .value(let value):
                return value
            case .followUp(let work):
                return try await ControlDeadline.shared.run(method: call.method, deadline: call.deadline,
                                                     startsTerminal: call.startsTerminal, work)
            }
        }
    }
}
