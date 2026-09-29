import Foundation
import JavaScriptCore

/// One console line produced by a REPL evaluation.
public struct BrowserReplOutputLine: Sendable, Equatable {
    /// `log`, `info`, `warn`, `error` or `debug`.
    public let level: String
    public let text: String

    public init(level: String, text: String) {
        self.level = level
        self.text = text
    }
}

/// The outcome of one REPL evaluation.
public struct BrowserReplEvalResult: Sendable, Equatable {
    /// Console output in order.
    public let lines: [BrowserReplOutputLine]
    /// Formatted uncaught error, or `nil` on success.
    public let error: String?
    /// Wall time of the evaluation in milliseconds.
    public let durationMilliseconds: Int

    public init(lines: [BrowserReplOutputLine], error: String?, durationMilliseconds: Int) {
        self.lines = lines
        self.error = error
        self.durationMilliseconds = durationMilliseconds
    }
}

/// A persistent REPL: one `JSContext` on its own thread, bound to a driver.
///
/// The session installs the native host (`__cmuxNative`, see
/// `docs/browser-repl/driver-protocol.md`), loads the runtime scripts, and
/// evaluates cells one at a time through the runtime's `__cmuxReplEval`.
/// Everything touching JavaScriptCore runs on `thread`.
public final class BrowserReplSession: @unchecked Sendable {
    /// Default per-evaluation timeout, as in `aside repl`.
    public static let defaultTimeout: Duration = .seconds(120)

    public let id: String
    private let bundle: BrowserReplRuntimeBundle
    private let driver: any BrowserReplDriver
    private let thread: BrowserReplJSThread
    private let fetcher: BrowserReplFetcher
    private let sleeper: any BrowserReplSleeping
    private let gate = BrowserReplEvalGate()
    private var scheduler: BrowserReplTimerScheduler<ContinuousClock>!

    private let stateLock = NSLock()
    private var closed = false
    private var lastUsedAt = ContinuousClock.now
    private var workingDirectory: String

    // JS-thread state.
    private var context: JSContext?
    private var loadError: String?
    private var fileSystem: BrowserReplFileSystem
    private var currentEval: EvalState?
    private var nextEvalID = 0

    private final class EvalState {
        let id: Int
        let start = ContinuousClock.now
        var lines: [BrowserReplOutputLine] = []
        var continuation: CheckedContinuation<BrowserReplEvalResult, Never>?
        var timeoutTask: Task<Void, Never>?

        init(id: Int, continuation: CheckedContinuation<BrowserReplEvalResult, Never>) {
            self.id = id
            self.continuation = continuation
        }
    }

    /// Creates a session. The context is created lazily on the first evaluation.
    /// - Parameters:
    ///   - id: Session name.
    ///   - cwd: Absolute root for the `fs` global.
    ///   - bundle: Runtime scripts.
    ///   - driver: Engine driver for the session's tabs.
    ///   - sleeper: Cancellable sleep used for evaluation timeouts.
    public init(
        id: String,
        cwd: String,
        bundle: BrowserReplRuntimeBundle,
        driver: any BrowserReplDriver,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock())
    ) {
        self.id = id
        self.workingDirectory = cwd
        self.bundle = bundle
        self.driver = driver
        self.sleeper = sleeper
        self.thread = BrowserReplJSThread(name: "com.cmux.browser-repl.\(id)")
        self.fetcher = BrowserReplFetcher(driver: driver)
        self.fileSystem = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: cwd))
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock()) { [weak self] id in
            self?.fireTimer(id)
        }
    }

    /// The fs root.
    public var cwd: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return workingDirectory
    }

    /// When the session last started an evaluation.
    public var lastUsed: ContinuousClock.Instant {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastUsedAt
    }

    /// Whether `close()` has run.
    public var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// Evaluates one cell. Cells run one at a time in submission order.
    /// - Parameters:
    ///   - code: JavaScript source.
    ///   - dialect: `aside` or `chatgpt`.
    ///   - cwd: New fs root, or `nil` to keep the current one.
    ///   - timeout: Evaluation timeout.
    public func evaluate(
        code: String,
        dialect: String,
        cwd: String? = nil,
        timeout: Duration = BrowserReplSession.defaultTimeout
    ) async -> BrowserReplEvalResult {
        await gate.acquire()
        let result = await evaluateLocked(code: code, dialect: dialect, cwd: cwd, timeout: timeout)
        await gate.release()
        return result
    }

    private func evaluateLocked(
        code: String,
        dialect: String,
        cwd: String?,
        timeout: Duration
    ) async -> BrowserReplEvalResult {
        let isClosed = stateLock.withLock {
            lastUsedAt = .now
            if let cwd { workingDirectory = cwd }
            return closed
        }
        guard !isClosed else {
            return BrowserReplEvalResult(lines: [], error: "Error: REPL session '\(id)' is closed", durationMilliseconds: 0)
        }
        return await withCheckedContinuation { continuation in
            let submitted = thread.perform { [self] in
                self.beginEval(code: code, dialect: dialect, cwd: cwd, timeout: timeout, continuation: continuation)
            }
            if !submitted {
                continuation.resume(returning: BrowserReplEvalResult(
                    lines: [],
                    error: "Error: REPL session '\(id)' is closed",
                    durationMilliseconds: 0
                ))
            }
        }
    }

    /// Stops timers, detaches the driver, fails a running evaluation and
    /// releases the context and thread.
    public func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        scheduler.invalidate()
        driver.detach()
        fetcher.invalidate()
        thread.perform { [self] in
            if let current = self.currentEval {
                self.finishEval(id: current.id, error: "Error: REPL session '\(self.id)' was closed")
            }
            self.context = nil
        }
        thread.stop()
    }

    // MARK: - JS thread

    private func beginEval(
        code: String,
        dialect: String,
        cwd: String?,
        timeout: Duration,
        continuation: CheckedContinuation<BrowserReplEvalResult, Never>
    ) {
        nextEvalID += 1
        let state = EvalState(id: nextEvalID, continuation: continuation)
        currentEval = state
        if let cwd, cwd != fileSystem.sandbox.root {
            var sandbox = BrowserReplFileSandbox(root: cwd)
            sandbox.inheritReadableFiles(from: fileSystem.sandbox)
            fileSystem = BrowserReplFileSystem(sandbox: sandbox)
            context?.objectForKeyedSubscript("__cmuxNative")?.setObject(cwd, forKeyedSubscript: "cwd" as NSString)
        }

        guard let context = ensureContext() else {
            finishEval(id: state.id, error: loadError ?? "Error: browser REPL runtime failed to load")
            return
        }
        guard let evalFunction = context.objectForKeyedSubscript("__cmuxReplEval"),
              !evalFunction.isUndefined else {
            finishEval(id: state.id, error: "Error: browser REPL runtime is not installed (missing __cmuxReplEval)")
            return
        }

        let evalID = state.id
        let sleeper = self.sleeper
        state.timeoutTask = Task { [weak self] in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            guard let self else { return }
            let milliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
            self.thread.perform {
                self.finishEval(id: evalID, error: "Error: REPL evaluation timed out after \(milliseconds)ms")
            }
        }

        context.exception = nil
        let promise = evalFunction.call(withArguments: [code, dialect])
        if let exception = context.exception {
            context.exception = nil
            finishEval(id: evalID, error: formatError(exception, in: context))
            return
        }
        guard let promise, promise.isObject, let then = promise.objectForKeyedSubscript("then"), !then.isUndefined else {
            finishEval(id: evalID, error: nil)
            return
        }
        let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] _ in
            self?.finishEval(id: evalID, error: nil)
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] reason in
            guard let self, let context = self.context else { return }
            let text = reason.map { self.formatError($0, in: context) } ?? "Error: undefined"
            self.finishEval(id: evalID, error: text)
        }
        promise.invokeMethod("then", withArguments: [
            JSValue(object: unsafeBitCast(onFulfilled, to: AnyObject.self), in: context) as Any,
            JSValue(object: unsafeBitCast(onRejected, to: AnyObject.self), in: context) as Any,
        ])
    }

    private func finishEval(id: Int, error: String?) {
        guard let state = currentEval, state.id == id else { return }
        currentEval = nil
        state.timeoutTask?.cancel()
        let elapsed = ContinuousClock.now - state.start
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let continuation = state.continuation
        state.continuation = nil
        continuation?.resume(returning: BrowserReplEvalResult(
            lines: state.lines,
            error: error,
            durationMilliseconds: milliseconds
        ))
    }

    private func formatError(_ value: JSValue, in context: JSContext) -> String {
        if let formatter = context.objectForKeyedSubscript("__cmuxFormatError"),
           !formatter.isUndefined,
           let formatted = formatter.call(withArguments: [value]),
           formatted.isString,
           let text = formatted.toString() {
            context.exception = nil
            return text
        }
        context.exception = nil
        if value.isObject,
           let stack = value.objectForKeyedSubscript("stack"),
           stack.isString,
           let stackText = stack.toString(),
           !stackText.isEmpty {
            let message = value.toString() ?? ""
            return stackText.hasPrefix(message) ? stackText : message + "\n" + stackText
        }
        return value.toString() ?? "Error"
    }

    private func ensureContext() -> JSContext? {
        if let context { return context }
        if loadError != nil { return nil }
        guard let context = JSContext() else {
            loadError = "Error: could not create a JavaScript context"
            return nil
        }
        context.name = "cmux browser repl \(id)"
        context.exceptionHandler = { context, exception in
            context?.exception = exception
        }
        installNativeHost(in: context)
        if bundle.replScripts.isEmpty {
            loadError = "Error: browser REPL runtime is not installed (no scripts in browser-repl)"
            return nil
        }
        for script in bundle.replScripts {
            context.exception = nil
            context.evaluateScript(script.source, withSourceURL: URL(string: "cmux-repl:///\(script.name)"))
            if let exception = context.exception {
                context.exception = nil
                loadError = "Error: browser REPL runtime failed to load \(script.name): \(formatError(exception, in: context))"
                return nil
            }
        }
        self.context = context
        driver.attach { [weak self] name, payload in
            self?.deliverEvent(name: name, payloadJSON: payload)
        }
        return context
    }

    private func installNativeHost(in context: JSContext) {
        guard let native = JSValue(newObjectIn: context) else { return }
        native.setObject(1, forKeyedSubscript: "version" as NSString)
        native.setObject(id, forKeyedSubscript: "sessionId" as NSString)
        native.setObject(fileSystem.sandbox.root, forKeyedSubscript: "cwd" as NSString)
        native.setObject(driver.capabilities, forKeyedSubscript: "capabilities" as NSString)
        native.setObject(fileSystem.temporaryRoot, forKeyedSubscript: "tmpdir" as NSString)
        native.setObject(NSHomeDirectory(), forKeyedSubscript: "homedir" as NSString)

        let print: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] level, text in
            guard let self, let state = self.currentEval else { return }
            state.lines.append(BrowserReplOutputLine(
                level: level?.toString() ?? "log",
                text: text?.toString() ?? ""
            ))
        }
        let setTimer: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] id, delay, repeating in
            guard let self, let id = id?.toInt32() else { return }
            let milliseconds = max(0, delay?.toDouble() ?? 0)
            let duration = Duration.milliseconds(Int64(milliseconds.isFinite ? milliseconds : 0))
            self.scheduler.schedule(id: Int(id), after: duration, repeating: repeating?.toBool() ?? false)
        }
        let clearTimer: @convention(block) (JSValue?) -> Void = { [weak self] id in
            guard let self, let id = id?.toInt32() else { return }
            self.scheduler.cancel(id: Int(id))
        }
        let driverCall: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] callID, method, params in
            guard let self, let callID = callID?.toInt32() else { return }
            let methodName = method?.toString() ?? ""
            let paramsJSON = params.flatMap { $0.isString ? $0.toString() : nil } ?? "{}"
            let driver = self.driver
            Task { [weak self] in
                let result = await driver.call(method: methodName, paramsJSON: paramsJSON)
                self?.thread.perform { self?.resolveCall(Int(callID), result) }
            }
        }
        let fetch: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] callID, request in
            guard let self, let callID = callID?.toInt32() else { return }
            let requestJSON = request?.toString() ?? "{}"
            let fetcher = self.fetcher
            Task { [weak self] in
                let result = await fetcher.fetch(requestJSON: requestJSON)
                self?.thread.perform { self?.resolveCall(Int(callID), result) }
            }
        }
        let fs: @convention(block) (JSValue?, JSValue?) -> String = { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"EINVAL","message":"closed"}}"# }
            let result = self.fileSystem.perform(
                operation?.toString() ?? "",
                arguments: BrowserReplJSON.object(arguments?.toString() ?? "{}")
            )
            switch result {
            case .success(let value):
                return BrowserReplJSON.encode(["ok": value]) ?? #"{"ok":null}"#
            case .failure(let error):
                return BrowserReplJSON.encode(["error": ["code": error.code, "message": error.message]])
                    ?? #"{"error":{"code":"EIO","message":"error"}}"#
            }
        }
        let readResource: @convention(block) (JSValue?) -> String? = { [weak self] path in
            guard let self, let path = path?.toString() else { return nil }
            return self.bundle.readResource(path)
        }

        native.setObject(unsafeBitCast(print, to: AnyObject.self), forKeyedSubscript: "print" as NSString)
        native.setObject(unsafeBitCast(setTimer, to: AnyObject.self), forKeyedSubscript: "setTimer" as NSString)
        native.setObject(unsafeBitCast(clearTimer, to: AnyObject.self), forKeyedSubscript: "clearTimer" as NSString)
        native.setObject(unsafeBitCast(driverCall, to: AnyObject.self), forKeyedSubscript: "driverCall" as NSString)
        native.setObject(unsafeBitCast(fetch, to: AnyObject.self), forKeyedSubscript: "fetch" as NSString)
        native.setObject(unsafeBitCast(fs, to: AnyObject.self), forKeyedSubscript: "fs" as NSString)
        native.setObject(unsafeBitCast(readResource, to: AnyObject.self), forKeyedSubscript: "readResource" as NSString)
        context.setObject(native, forKeyedSubscript: "__cmuxNative" as NSString)
    }

    private func resolveCall(_ callID: Int, _ result: Result<String, BrowserReplDriverError>) {
        guard let context,
              let resolve = context.objectForKeyedSubscript("__cmuxHostOnResult"),
              !resolve.isUndefined else { return }
        switch result {
        case .success(let json):
            resolve.call(withArguments: [callID, NSNull(), json])
        case .failure(let error):
            resolve.call(withArguments: [callID, error.json, NSNull()])
        }
        context.exception = nil
    }

    private func fireTimer(_ id: Int) {
        thread.perform { [weak self] in
            guard let self, let context = self.context,
                  let handler = context.objectForKeyedSubscript("__cmuxHostOnTimer"),
                  !handler.isUndefined else { return }
            handler.call(withArguments: [id])
            context.exception = nil
        }
    }

    private func deliverEvent(name: String, payloadJSON: String) {
        thread.perform { [weak self] in
            guard let self else { return }
            if name == "download.finished",
               let path = BrowserReplJSON.object(payloadJSON)["path"] as? String {
                self.fileSystem.sandbox.allowReading(path)
            }
            guard let context = self.context,
                  let handler = context.objectForKeyedSubscript("__cmuxHostOnEvent"),
                  !handler.isUndefined else { return }
            handler.call(withArguments: [name, payloadJSON])
            context.exception = nil
        }
    }
}

/// A cancellable sleep, injected so tests control time.
public protocol BrowserReplSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Sleeps on a `Clock`.
public struct BrowserReplClockSleeper<C: Clock>: BrowserReplSleeping where C.Duration == Duration {
    let clock: C

    public init(clock: C) {
        self.clock = clock
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// Serializes evaluations of one session without blocking a thread.
actor BrowserReplEvalGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
