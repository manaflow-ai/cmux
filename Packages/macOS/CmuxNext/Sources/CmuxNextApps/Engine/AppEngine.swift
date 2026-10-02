import Foundation
import JavaScriptCore

/// DEV prototype engine (app-platform.md section 4): runs one app's
/// JavaScript in its own JavaScriptCore VM on a private serial executor,
/// never the main thread, behind the same `__cmuxAppNative` ABI the Rust
/// QuickJS app host will implement. In-process and Apple-only with no OS
/// sandbox, so the registry loads only first-party and `local/` apps.
/// Every call is scope-checked here before it reaches the sink; a single
/// evaluation longer than 250 ms stops the VM.
public actor AppEngine {
    nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    let configuration: AppEngineConfiguration
    public nonisolated var manifest: AppManifest { configuration.manifest }
    public private(set) var state: AppEngineState = .idle
    /// Whether the hard evaluation limit is active (needs the JSC SPI).
    public private(set) var hasWatchdog = false

    var context: JSContext?
    let watchdog = AppWatchdog()
    var lastException: String?
    /// Calls the app issued that the sink has not answered.
    var pendingCalls: [Int: Task<Void, Never>] = [:]
    var timers: [Int: (repeats: Bool, ms: Int, task: Task<Void, Never>)] = [:]
    var nextTimer = 1
    var subscriptions: [Int: UInt64] = [:]
    var nextSubscription = 1
    var commands: [Int: CheckedContinuation<Result<AppJSON, AppOperationError>, Never>] = [:]
    var nextCommand = 1
    /// Nonzero while a tap or menu pick handler runs (ops get origin `user`).
    var gestureDepth = 0

    public init(configuration: AppEngineConfiguration) {
        self.configuration = configuration
        queue = DispatchSerialQueue(label: "cmux.apps.\(configuration.manifest.id)", qos: .userInitiated)
    }

    /// Loads the runtime and the app's `main`, then `__cmuxAppInit`.
    public func start() throws(AppEngineError) {
        guard state == .idle else { return }
        guard let main = configuration.manifest.main else {
            state = .running
            return
        }
        let runtime: String
        let script: String
        do {
            runtime = try String(contentsOf: configuration.runtimeScript, encoding: .utf8)
            let mainURL = configuration.bundleDirectory.appending(path: main).standardizedFileURL
            guard mainURL.path.hasPrefix(configuration.bundleDirectory.standardizedFileURL.path) else { throw AppEngineError("main escapes the bundle") }
            script = try String(contentsOf: mainURL, encoding: .utf8)
        } catch {
            try fail("cannot read the app: \(error)")
        }
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else { try fail("cannot create a JavaScript VM") }
        context.name = configuration.manifest.id
        self.context = context
        hasWatchdog = watchdog.install(on: context, limit: configuration.evaluationLimit)
        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "exception"
            self?.assumeIsolated { $0.lastException = text }
        }
        installNative(in: context)
        state = .running
        try evaluate(runtime, name: "cmux-app-runtime.js")
        try evaluate(script, name: main)
        let initJSON: AppJSON = [
            "app": ["id": .string(configuration.manifest.id), "version": .string(configuration.manifest.version)],
            "settings": configuration.settings,
            "apiVersion": .string(configuration.scopes.apiVersion),
            // Every op a declared scope could allow: a scope granted later
            // works without a reload; the host checks the live grant per call.
            "ops": .array(configuration.scopes.allowedOps(granted: declaredScopes).map(AppJSON.string)),
        ]
        let result = enter("__cmuxAppInit", [initJSON.jsonText])
        if let result, !result.isEmpty, !(result == "undefined") { try fail("init: \(result)") }
    }

    /// Renders `export` as mount `mountID`; returns the render error, if any.
    @discardableResult
    public func mount(_ mountID: String, export: String, context mountContext: AppJSON = .object([:])) -> String? {
        guard state == .running else { return stoppedReason }
        let result = enter("__cmuxAppMount", [mountID, export, mountContext.jsonText])
        if case .stopped(let reason) = state { return reason }
        return result.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func unmount(_ mountID: String) {
        guard state == .running else { return }
        _ = enter("__cmuxAppUnmount", [mountID])
    }

    /// Sends a UI event to a mounted node. Taps and menu picks are user
    /// gestures: ops the handler issues during this turn carry origin `user`.
    public func dispatch(_ mountID: String, node: String, event: String, payload: AppJSON = .object([:])) {
        guard state == .running else { return }
        let gesture = event == "tap" || event == "menu"
        if gesture { gestureDepth += 1 }
        defer { if gesture { gestureDepth -= 1 } }
        _ = enter("__cmuxAppDispatch", [mountID, node, event, payload.jsonText])
    }

    public func setSettings(_ settings: AppJSON) {
        guard state == .running else { return }
        _ = enter("__cmuxAppSetSettings", [settings.jsonText])
    }

    /// Runs a command export and waits for its completion.
    public func runCommand(_ export: String, arguments: AppJSON = .object([:])) async -> Result<AppJSON, AppOperationError> {
        guard state == .running else { return .failure(AppOperationError(code: "app.stopped", message: stoppedReason ?? "not running")) }
        let id = nextCommand
        nextCommand += 1
        return await withCheckedContinuation { continuation in
            commands[id] = continuation
            _ = enter("__cmuxAppRunCommand", [export, arguments.jsonText, id])
        }
    }

    /// Stops the VM: cancels timers, calls and subscriptions, releases the context.
    public func stop(reason: String = "stopped") {
        if case .stopped = state { return }
        state = .stopped(reason)
        for task in pendingCalls.values { task.cancel() }
        pendingCalls.removeAll()
        for timer in timers.values { timer.task.cancel() }
        timers.removeAll()
        for token in subscriptions.values { configuration.events.unsubscribe(token) }
        subscriptions.removeAll()
        for continuation in commands.values { continuation.resume(returning: .failure(AppOperationError(code: "app.stopped", message: reason))) }
        commands.removeAll()
        context?.exceptionHandler = nil
        context = nil
        configuration.output(.stopped(reason: reason))
    }

    private var declaredScopes: Set<String> {
        Set((configuration.manifest.scopes + configuration.manifest.optionalScopes).map(\.scope))
    }

    var stoppedReason: String? {
        if case .stopped(let reason) = state { return reason }
        return nil
    }

    private func fail(_ message: String) throws(AppEngineError) -> Never {
        stop(reason: message)
        throw AppEngineError(message)
    }

    private func evaluate(_ source: String, name: String) throws(AppEngineError) {
        guard let context else { throw AppEngineError(stoppedReason ?? "not running") }
        lastException = nil
        watchdog.reset()
        context.evaluateScript(source, withSourceURL: URL(string: "cmux-app://\(configuration.manifest.id)/\(name)"))
        if watchdog.didFire { try fail(Self.limitReason) }
        if let exception = lastException { try fail("\(name): \(exception)") }
    }

    static let limitReason = "app.limit: an evaluation ran longer than 250 ms"

    /// Calls a runtime entry point; returns its string result. A watchdog
    /// trip stops the VM.
    func enter(_ function: String, _ arguments: [Any]) -> String? {
        guard let context, let fn = context.objectForKeyedSubscript(function), !fn.isUndefined else { return nil }
        lastException = nil
        watchdog.reset()
        let value = fn.call(withArguments: arguments)
        if watchdog.didFire {
            stop(reason: Self.limitReason)
            return Self.limitReason
        }
        if let exception = lastException {
            configuration.output(.log(level: "error", message: "\(function): \(exception)"))
            return exception
        }
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }
}
