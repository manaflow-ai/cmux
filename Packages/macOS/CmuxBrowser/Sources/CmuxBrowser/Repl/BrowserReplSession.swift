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
    private let watchdog = BrowserReplWatchdog()

    // Lifecycle state, guarded by `stateLock`. Submitting work to `thread`
    // happens under the same lock, so `close()` and `evaluate()` see one
    // order: an evaluation either reaches the thread before close's cleanup
    // or sees `closed`.
    private let stateLock = NSLock()
    private var closed = false
    private var lastUsedAt = ContinuousClock.now
    private var workingDirectory: String
    private var currentEval: EvalState?
    private var nextEvalID = 0
    /// Driver calls and fetches in flight; `close()` cancels them.
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextInFlightID = 0
    /// The per-session temporary directory created when no cwd was given.
    private let ownedWorkingDirectory: String?
    private let homeDirectory: String

    // JS-thread state.
    private var context: JSContext?
    private var loadError: String?
    private var fileSystem: BrowserReplFileSystem

    /// One evaluation's result. It is finished exactly once: by the JS
    /// thread when the cell settles, or from outside it by the timeout or
    /// `close()`, so a wedged JS thread can never strand the caller.
    private final class EvalState: @unchecked Sendable {
        let id: Int
        let start = ContinuousClock.now
        private let lock = NSLock()
        private var lines: [BrowserReplOutputLine] = []
        private var continuation: CheckedContinuation<BrowserReplEvalResult, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false

        init(id: Int, continuation: CheckedContinuation<BrowserReplEvalResult, Never>) {
            self.id = id
            self.continuation = continuation
        }

        var isFinished: Bool { lock.withLock { finished } }

        func append(_ line: BrowserReplOutputLine) {
            lock.withLock {
                if !finished { lines.append(line) }
            }
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            let cancelNow: Bool = lock.withLock {
                if finished { return true }
                timeoutTask = task
                return false
            }
            if cancelNow { task.cancel() }
        }

        /// Resumes the caller unless already done. Returns whether this call finished it.
        @discardableResult
        func finish(error: String?) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return false
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let lines = self.lines
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            lock.unlock()
            timeoutTask?.cancel()
            let elapsed = ContinuousClock.now - start
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            continuation?.resume(returning: BrowserReplEvalResult(
                lines: lines,
                error: error,
                durationMilliseconds: milliseconds
            ))
            return true
        }
    }

    /// Creates a session. The context is created lazily on the first evaluation.
    /// - Parameters:
    ///   - id: Session name.
    ///   - cwd: Absolute root for the `fs` global, or `nil` for a new
    ///     directory of this session's own under the temporary directory
    ///     (removed on close when still empty). `/`, the home directory and
    ///     directories containing it are refused when evaluating.
    ///   - bundle: Runtime scripts.
    ///   - driver: Engine driver for the session's tabs.
    ///   - sleeper: Cancellable sleep used for evaluation timeouts.
    ///   - temporaryDirectory: The second `fs` root; `nil` uses `NSTemporaryDirectory()`.
    ///   - homeDirectory: The user's home directory, refused as a root;
    ///     `nil` uses `NSHomeDirectory()`.
    public init(
        id: String,
        cwd: String?,
        bundle: BrowserReplRuntimeBundle,
        driver: any BrowserReplDriver,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock()),
        temporaryDirectory: String? = nil,
        homeDirectory: String? = nil
    ) {
        let temporaryRoot = BrowserReplFileSandbox.canonicalize(
            BrowserReplFileSandbox.lexicallyNormalized(temporaryDirectory ?? NSTemporaryDirectory())
        )
        let resolvedCwd: String
        if let cwd {
            resolvedCwd = cwd
            ownedWorkingDirectory = nil
        } else {
            resolvedCwd = Self.makeSessionDirectory(id: id, temporaryRoot: temporaryRoot)
            ownedWorkingDirectory = resolvedCwd
        }
        self.id = id
        self.workingDirectory = resolvedCwd
        self.homeDirectory = homeDirectory ?? NSHomeDirectory()
        self.bundle = bundle
        self.driver = driver
        self.sleeper = sleeper
        self.thread = BrowserReplJSThread(name: "com.cmux.browser-repl.\(id)")
        self.fetcher = BrowserReplFetcher(driver: driver)
        self.fileSystem = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: resolvedCwd),
            temporaryDirectory: temporaryRoot
        )
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock()) { [weak self] id in
            self?.fireTimer(id)
        }
    }

    /// Creates `<temporaryRoot>/cmux-browser-repl/<id>-<random>` for a
    /// session started without a cwd.
    private static func makeSessionDirectory(id: String, temporaryRoot: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeID = String(String.UnicodeScalarView(id.unicodeScalars.prefix(64).map { allowed.contains($0) ? $0 : "_" }))
        let name = "\(safeID)-\(UUID().uuidString.prefix(8))"
        let path = (temporaryRoot == "/" ? "" : temporaryRoot) + "/cmux-browser-repl/" + name
        // A failure surfaces as ENOENT on the first fs write.
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
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
    ///   - cwd: New fs root, or `nil` to keep the current one.
    ///   - timeout: Evaluation timeout.
    ///   - maxOutput: Characters of output the cell prints before the rest
    ///     goes to a file (`0` for no limit), or `nil` for the runtime's
    ///     default (`repl-host.js`, `createOutputGate`).
    public func evaluate(
        code: String,
        cwd: String? = nil,
        timeout: Duration = BrowserReplSession.defaultTimeout,
        maxOutput: Int? = nil
    ) async -> BrowserReplEvalResult {
        await gate.acquire()
        let result = await evaluateLocked(code: code, cwd: cwd, timeout: timeout, maxOutput: maxOutput)
        await gate.release()
        return result
    }

    private func evaluateLocked(
        code: String,
        cwd: String?,
        timeout: Duration,
        maxOutput: Int?
    ) async -> BrowserReplEvalResult {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            lastUsedAt = .now
            var refusal: String?
            if closed {
                refusal = "Error: REPL session '\(id)' is closed"
            } else if let reason = BrowserReplFileSandbox.rootRejection(cwd ?? workingDirectory, homeDirectory: homeDirectory) {
                refusal = "Error: \(reason)"
            }
            if let refusal {
                stateLock.unlock()
                continuation.resume(returning: BrowserReplEvalResult(lines: [], error: refusal, durationMilliseconds: 0))
                return
            }
            if let cwd { workingDirectory = cwd }
            nextEvalID += 1
            let state = EvalState(id: nextEvalID, continuation: continuation)
            currentEval = state
            let submitted = thread.perform { [self] in
                self.beginEval(state, code: code, cwd: cwd, maxOutput: maxOutput)
            }
            stateLock.unlock()
            guard submitted else {
                finish(state, error: "Error: REPL session '\(id)' is closed")
                return
            }
            let sleeper = self.sleeper
            state.setTimeoutTask(Task { [weak self] in
                do {
                    try await sleeper.sleep(for: timeout)
                } catch {
                    return
                }
                self?.timeOut(state, after: timeout)
            })
        }
    }

    /// Stops timers, cancels in-flight driver calls and fetches, detaches
    /// the driver, fails a running evaluation and releases the context and
    /// thread. A script still running on the JS thread is terminated.
    public func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let running = currentEval
        currentEval = nil
        let tasks = Array(inFlight.values)
        inFlight.removeAll()
        watchdog.requestTermination()
        thread.perform { [self] in
            self.context = nil
        }
        thread.stop()
        stateLock.unlock()
        for task in tasks { task.cancel() }
        scheduler.invalidate()
        driver.detach()
        fetcher.invalidate()
        running?.finish(error: "Error: REPL session '\(id)' was closed")
        if let ownedWorkingDirectory {
            // Only an empty directory goes; files the session wrote stay.
            rmdir(ownedWorkingDirectory)
        }
    }

    /// Finishes `state` and forgets it when it is still the current evaluation.
    private func finish(_ state: EvalState, error: String?) {
        stateLock.withLock {
            if currentEval === state { currentEval = nil }
        }
        state.finish(error: error)
    }

    /// The evaluation timeout: the caller gets the timeout error now, from
    /// outside the JS thread. A script looping on the thread is terminated by
    /// the watchdog; then the runtime cancels the cell, so the cells after it
    /// run. Both are queued on the thread before the caller can submit
    /// another cell.
    private func timeOut(_ state: EvalState, after timeout: Duration) {
        let isCurrent = stateLock.withLock { currentEval === state && !closed }
        guard isCurrent else { return }
        let milliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
        let message = "Error: REPL evaluation timed out after \(milliseconds)ms"
        watchdog.requestTermination()
        thread.perform { [self] in
            self.watchdog.clearTermination()
            self.cancelRunningCell(message)
        }
        finish(state, error: message)
    }

    /// Asks the runtime to drop the running cell (`__cmuxReplCancel`).
    private func cancelRunningCell(_ message: String) {
        guard let context else { return }
        watchdog.absorbTermination(in: context)
        guard let cancel = context.objectForKeyedSubscript("__cmuxReplCancel"),
              !cancel.isUndefined else { return }
        cancel.call(withArguments: [message])
        context.exception = nil
    }

    /// Runs `body` as an in-flight task that `close()` cancels. Returns
    /// false, without running it, when the session is closed.
    @discardableResult
    private func track(_ body: @escaping @Sendable () async -> Void) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return false }
        nextInFlightID += 1
        let taskID = nextInFlightID
        // The task removes itself; it waits for the lock held here, so the
        // entry exists before the removal runs.
        inFlight[taskID] = Task { [weak self] in
            await body()
            guard let self else { return }
            self.stateLock.withLock { _ = self.inFlight.removeValue(forKey: taskID) }
        }
        return true
    }

    // MARK: - JS thread

    private func beginEval(
        _ state: EvalState,
        code: String,
        cwd: String?,
        maxOutput: Int?
    ) {
        // A timeout or close() may have finished the evaluation before the
        // thread reached it.
        guard !state.isFinished, !isClosedNow else { return }
        if let cwd, cwd != fileSystem.sandbox.root {
            var sandbox = BrowserReplFileSandbox(root: cwd)
            sandbox.inheritReadableFiles(from: fileSystem.sandbox)
            fileSystem = BrowserReplFileSystem(sandbox: sandbox, temporaryDirectory: fileSystem.temporaryRoot)
            context?.objectForKeyedSubscript("__cmuxNative")?.setObject(cwd, forKeyedSubscript: "cwd" as NSString)
        }

        guard let context = ensureContext() else {
            finish(state, error: loadError ?? "Error: browser REPL runtime failed to load")
            return
        }
        guard let evalFunction = context.objectForKeyedSubscript("__cmuxReplEval"),
              !evalFunction.isUndefined else {
            finish(state, error: "Error: browser REPL runtime is not installed (missing __cmuxReplEval)")
            return
        }

        watchdog.absorbTermination(in: context)
        context.exception = nil
        // The runtime's options argument: `{ "maxOutput": characters }`.
        var arguments: [Any] = [code]
        if let maxOutput { arguments.append("{\"maxOutput\":\(max(0, maxOutput))}") }
        let promise = evalFunction.call(withArguments: arguments)
        if let exception = context.exception {
            context.exception = nil
            finish(state, error: state.isFinished ? nil : formatError(exception, in: context))
            return
        }
        guard let promise, promise.isObject, let then = promise.objectForKeyedSubscript("then"), !then.isUndefined else {
            finish(state, error: nil)
            return
        }
        let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] _ in
            self?.finish(state, error: nil)
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] reason in
            guard let self, !state.isFinished, let context = self.context else { return }
            let text = reason.map { self.formatError($0, in: context) } ?? "Error: undefined"
            self.finish(state, error: text)
        }
        promise.invokeMethod("then", withArguments: [
            JSValue(object: unsafeBitCast(onFulfilled, to: AnyObject.self), in: context) as Any,
            JSValue(object: unsafeBitCast(onRejected, to: AnyObject.self), in: context) as Any,
        ])
    }

    private var isClosedNow: Bool {
        stateLock.withLock { closed }
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
        if loadError != nil || isClosedNow { return nil }
        guard let context = JSContext() else {
            loadError = "Error: could not create a JavaScript context"
            return nil
        }
        context.name = "cmux browser repl \(id)"
        context.exceptionHandler = { context, exception in
            context?.exception = exception
        }
        watchdog.install(on: context)
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
        native.setObject(homeDirectory, forKeyedSubscript: "homedir" as NSString)

        let print: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] level, text in
            guard let self, let state = self.stateLock.withLock({ self.currentEval }) else { return }
            state.append(BrowserReplOutputLine(
                level: level?.toString() ?? "log",
                text: text?.toString() ?? ""
            ))
        }
        let setTimer: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] id, delay, repeating in
            guard let self, let id = id?.toInt32() else { return }
            let duration = Duration.milliseconds(BrowserReplSession.timerDelayMilliseconds(delay?.toDouble()))
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
            let started = self.track { [weak self] in
                let result = await driver.call(method: methodName, paramsJSON: paramsJSON)
                self?.thread.perform { self?.resolveCall(Int(callID), result) }
            }
            if !started { self.resolveCall(Int(callID), .failure(Self.closedError)) }
        }
        let fetch: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] callID, request in
            guard let self, let callID = callID?.toInt32() else { return }
            let requestJSON = request?.toString() ?? "{}"
            let fetcher = self.fetcher
            let started = self.track { [weak self] in
                let result = await fetcher.fetch(requestJSON: requestJSON)
                self?.thread.perform { self?.resolveCall(Int(callID), result) }
            }
            if !started { self.resolveCall(Int(callID), .failure(Self.closedError)) }
        }
        let fs: @convention(block) (JSValue?, JSValue?) -> String = { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"EINVAL","message":"closed"}}"# }
            let result = self.fileSystem.perform(
                operation?.toString() ?? "",
                arguments: JSONSerialization.browserReplObject(arguments?.toString() ?? "{}")
            )
            switch result {
            case .success(let value):
                return JSONSerialization.browserReplString(["ok": value]) ?? #"{"ok":null}"#
            case .failure(let error):
                return JSONSerialization.browserReplString(["error": ["code": error.code, "message": error.message]])
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

    private static let closedError = BrowserReplDriverError(code: "closed", message: "the REPL session was closed")

    /// The longest timer delay, 2^31-1 ms (about 24.8 days), as browsers and
    /// Node cap `setTimeout`.
    static let maxTimerDelayMilliseconds: Int64 = 2_147_483_647

    /// A JavaScript timer delay as whole milliseconds: NaN, negative and
    /// missing delays are 0, larger ones are capped at
    /// `maxTimerDelayMilliseconds`, so no delay can trap the conversion.
    static func timerDelayMilliseconds(_ delay: Double?) -> Int64 {
        guard let delay, delay.isNaN == false, delay > 0 else { return 0 }
        return delay >= Double(maxTimerDelayMilliseconds) ? maxTimerDelayMilliseconds : Int64(delay)
    }

    private func resolveCall(_ callID: Int, _ result: Result<String, BrowserReplDriverError>) {
        guard let context else { return }
        watchdog.absorbTermination(in: context)
        guard let resolve = context.objectForKeyedSubscript("__cmuxHostOnResult"),
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
            guard let self, let context = self.context else { return }
            self.watchdog.absorbTermination(in: context)
            guard let handler = context.objectForKeyedSubscript("__cmuxHostOnTimer"),
                  !handler.isUndefined else { return }
            handler.call(withArguments: [id])
            context.exception = nil
        }
    }

    private func deliverEvent(name: String, payloadJSON: String) {
        thread.perform { [weak self] in
            guard let self else { return }
            if name == "download.finished",
               let path = JSONSerialization.browserReplObject(payloadJSON)["path"] as? String {
                self.fileSystem.sandbox.allowReading(path)
            }
            guard let context = self.context else { return }
            self.watchdog.absorbTermination(in: context)
            guard let handler = context.objectForKeyedSubscript("__cmuxHostOnEvent"),
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
