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
    /// Default per-evaluation timeout, as in reference A's REPL.
    public static let defaultTimeout: Duration = .seconds(120)

    /// Default limit for JavaScript that runs outside a cell.
    public static let defaultCallbackTimeLimit: Duration = .seconds(10)

    public let id: String
    private let bundle: BrowserReplRuntimeBundle
    private let driver: any BrowserReplDriver
    /// The session's JavaScript thread (internal for tests).
    let thread: BrowserReplJSThread
    private let fetcher: BrowserReplFetcher
    /// Secrets, the domain policy and redaction (see BrowserReplBoundary).
    private let boundary: BrowserReplBoundary
    private let sleeper: any BrowserReplSleeping
    private let gate = BrowserReplEvalGate()
    private var scheduler: BrowserReplTimerScheduler<ContinuousClock>!
    private let watchdog: BrowserReplWatchdog

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
    /// Driver calls and fetches in flight; `close()` cancels them, and a
    /// cell's timeout cancels the fetches it started.
    private var inFlight: [Int: InFlightWork] = [:]
    private var nextInFlightID = 0
    /// Fetches running now, at most `maxConcurrentFetches`.
    private var runningFetches = 0
    /// Fetches waiting for a running one to finish, oldest first.
    private var queuedFetches: [PendingFetch] = []
    /// The per-session temporary directory created when no cwd was given.
    private let ownedWorkingDirectory: String?
    /// The session's private temporary directory (mode 0700): `os.tmpdir()`
    /// in the REPL, where output spill files go, and the only `fs` root
    /// besides the working directory.
    private let privateTemporaryDirectory: String
    private let homeDirectory: String

    // JS-thread state.
    private var context: JSContext?
    /// The `__cmuxNative` object; the runtime deletes the global.
    private var nativeHost: JSValue?
    /// The runtime's entry points, taken off the global object once the
    /// runtime loaded, so no cell can call them.
    private var entryPoints: EntryPoints?
    private var loadError: String?
    private var fileSystem: BrowserReplFileSystem

    /// One evaluation's result. It is finished exactly once: by the JS
    /// thread when the cell settles, or from outside it by the timeout or
    /// `close()`, so a wedged JS thread can never strand the caller.
    ///
    /// Past `maxRetainedOutputBytes` of output, whatever reaches the native
    /// print (the runtime's own gate stops well before that), the rest goes
    /// to `<tmpdir>/output-<id>.txt` instead of memory.
    private final class EvalState: @unchecked Sendable {
        let id: Int
        let start = ContinuousClock.now
        private let lock = NSLock()
        private var lines: [BrowserReplOutputLine] = []
        private var continuation: CheckedContinuation<BrowserReplEvalResult, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false
        private let spillPath: String
        private var retainedBytes = 0
        private var spilledBytes = 0
        private var spill: FileHandle?
        private var spilling = false

        init(id: Int, spillDirectory: String, continuation: CheckedContinuation<BrowserReplEvalResult, Never>) {
            self.id = id
            self.spillPath = spillDirectory + "/output-\(id).txt"
            self.continuation = continuation
        }

        var isFinished: Bool { lock.withLock { finished } }

        /// Whether the session's thread has reached this evaluation. It is
        /// current from submission on, but JavaScript that runs on the
        /// thread before it began (a callback queued ahead of it) is not
        /// its work.
        private var began = false
        var hasBegun: Bool { lock.withLock { began } }

        /// Call on the session's thread when it starts this evaluation.
        func markBegun() {
            lock.withLock { began = true }
        }

        func append(_ line: BrowserReplOutputLine) {
            lock.withLock {
                guard !finished else { return }
                let size = line.text.utf8.count + 1
                if !spilling, retainedBytes + size <= BrowserReplSession.maxRetainedOutputBytes {
                    retainedBytes += size
                    lines.append(line)
                    return
                }
                if !spilling {
                    spilling = true
                    // O_EXCL: never write into a file that is already there.
                    let descriptor = open(spillPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    if descriptor >= 0 { spill = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) }
                    lines.append(BrowserReplOutputLine(
                        level: "info",
                        text: spill == nil ? "# output past this point was dropped" : "# output continues in \(spillPath)"
                    ))
                }
                spilledBytes += size
                try? spill?.write(contentsOf: Data((line.text + "\n").utf8))
            }
        }

        /// The note that ends spilled output. Call with `lock` held.
        private func spillSummaryLocked() -> BrowserReplOutputLine? {
            guard spilling else { return nil }
            try? spill?.close()
            spill = nil
            let total = retainedBytes + spilledBytes
            let destination = FileManager.default.fileExists(atPath: spillPath) ? "full output: \(spillPath)" : "the rest was dropped"
            return BrowserReplOutputLine(
                level: "info",
                text: "# output truncated: \(retainedBytes) of \(total) bytes shown; \(destination)"
            )
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
            if let summary = spillSummaryLocked() { self.lines.append(summary) }
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

    /// The most fetches one session runs at once. Each holds up to
    /// `BrowserReplFetcher.defaultMaxBodyBytes` of body, so this also bounds
    /// a session's fetch buffers; later fetches wait in order.
    static let maxConcurrentFetches = 16

    /// The most timers a session has scheduled, or fired with their callback
    /// not yet run, at once; `setTimer` returns false past it.
    static let maxPendingTimers = 10_000

    /// The most output, in UTF-8 bytes, one evaluation keeps in memory; the
    /// rest goes to a file in the session's temporary directory.
    static let maxRetainedOutputBytes = 16 << 20

    /// A tracked task, and the evaluation that was running when it started.
    private struct InFlightWork {
        let task: Task<Void, Never>
        let evalID: Int?
        let isFetch: Bool
    }

    /// A fetch the runtime asked for, waiting for a slot or running.
    private struct PendingFetch {
        let callID: Int
        let requestJSON: String
        let evalID: Int?
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
    ///   - temporaryDirectory: The app's temporary directory, under which the
    ///     session creates its private one; `nil` uses `NSTemporaryDirectory()`.
    ///   - homeDirectory: The user's home directory, refused as a root;
    ///     `nil` uses `NSHomeDirectory()`.
    ///   - callbackTimeLimit: How long JavaScript that runs outside a cell
    ///     (a timer or event callback after its cell ended) may run before
    ///     it is terminated.
    public init(
        id: String,
        cwd: String?,
        bundle: BrowserReplRuntimeBundle,
        driver: any BrowserReplDriver,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock()),
        temporaryDirectory: String? = nil,
        homeDirectory: String? = nil,
        callbackTimeLimit: Duration = BrowserReplSession.defaultCallbackTimeLimit
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
        privateTemporaryDirectory = Self.makeSessionDirectory(id: id, temporaryRoot: temporaryRoot, suffix: "-tmp", mode: 0o700)
        self.id = id
        self.workingDirectory = resolvedCwd
        self.homeDirectory = homeDirectory ?? NSHomeDirectory()
        self.bundle = bundle
        self.driver = driver
        self.boundary = BrowserReplBoundary(typedSecrets: { driver.typedSecretRedaction() })
        self.sleeper = sleeper
        self.thread = BrowserReplJSThread(name: "com.cmux.browser-repl.\(id)")
        self.watchdog = BrowserReplWatchdog(callbackTimeLimit: callbackTimeLimit)
        self.fetcher = BrowserReplFetcher(driver: driver)
        self.fileSystem = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: resolvedCwd),
            temporaryDirectory: privateTemporaryDirectory
        )
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock(), maximumTimers: Self.maxPendingTimers) { [weak self] id in
            self?.fireTimer(id)
        }
        let boundary = self.boundary
        fetcher.setBlockReason { url in boundary.blockReason(url) }
    }

    /// Creates `<temporaryRoot>/cmux-browser-repl/<id>-<random><suffix>`, a
    /// new directory of the session's own: its working directory when it
    /// was started without a cwd, and its private temporary directory.
    private static func makeSessionDirectory(id: String, temporaryRoot: String, suffix: String = "", mode: mode_t = 0o755) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeID = String(String.UnicodeScalarView(id.unicodeScalars.prefix(64).map { allowed.contains($0) ? $0 : "_" }))
        let parent = (temporaryRoot == "/" ? "" : temporaryRoot) + "/cmux-browser-repl"
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var path = ""
        // mkdir(2) creates the directory itself, never one that already
        // exists, so no other session's directory is ever reused.
        for _ in 0..<8 {
            path = parent + "/\(safeID)-\(UUID().uuidString.prefix(8))\(suffix)"
            // The umask can only narrow `mode`.
            if mkdir(path, mode) == 0 { break }
        }
        // A failure surfaces as ENOENT on the first fs write.
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
            let state = EvalState(id: nextEvalID, spillDirectory: privateTemporaryDirectory, continuation: continuation)
            currentEval = state
            watchdog.setCurrentEval(state.id)
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
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll()
        queuedFetches.removeAll()
        runningFetches = 0
        // Every script from now on, also one a block queued before this
        // runs, is terminated; a timeout's cleanup cannot clear that.
        watchdog.close()
        thread.perform { [self] in
            self.entryPoints = nil
            self.nativeHost = nil
            self.context = nil
        }
        thread.stop()
        stateLock.unlock()
        for task in tasks { task.cancel() }
        scheduler.invalidate()
        driver.detach()
        fetcher.invalidate()
        running?.finish(error: "Error: REPL session '\(id)' was closed")
        // Only an empty directory goes; files the session wrote stay, since
        // a one-shot run prints paths (spilled output, screenshots) that the
        // caller reads after the session has closed.
        if let ownedWorkingDirectory {
            rmdir(ownedWorkingDirectory)
        }
        rmdir(privateTemporaryDirectory)
    }

    /// Finishes `state` and forgets it when it is still the current evaluation.
    private func finish(_ state: EvalState, error: String?) {
        stateLock.withLock {
            if currentEval === state {
                currentEval = nil
                watchdog.setCurrentEval(nil)
            }
        }
        state.finish(error: error.map(boundary.redact))
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
            self.cancelRunningCell(message, evalID: state.id)
        }
        finish(state, error: message)
        cancelFetches(ofEval: state.id)
    }

    /// Cancels the running fetches cell `evalID` started and fails its queued ones.
    private func cancelFetches(ofEval evalID: Int) {
        let (tasks, dropped): ([Task<Void, Never>], [PendingFetch]) = stateLock.withLock {
            let tasks = inFlight.values.filter { $0.isFetch && $0.evalID == evalID }.map(\.task)
            let dropped = queuedFetches.filter { $0.evalID == evalID }
            queuedFetches.removeAll { $0.evalID == evalID }
            return (tasks, dropped)
        }
        for task in tasks { task.cancel() }
        guard !dropped.isEmpty else { return }
        thread.perform { [weak self] in
            for fetch in dropped { self?.resolveCall(fetch.callID, .failure(Self.cancelledFetchError)) }
        }
    }

    private static let cancelledFetchError = BrowserReplDriverError(
        code: "cancelled",
        message: "fetch: cancelled because the cell that started it timed out"
    )

    /// Runs the fetch now, or queues it while `maxConcurrentFetches` run.
    /// Returns false when the session is closed. The evaluation running
    /// when the runtime asked owns the fetch, so its timeout cancels it.
    private func startOrQueueFetch(callID: Int, requestJSON: String) -> Bool {
        stateLock.withLock {
            guard !closed else { return false }
            let fetch = PendingFetch(callID: callID, requestJSON: requestJSON, evalID: currentEval?.id)
            if runningFetches < Self.maxConcurrentFetches {
                startFetchLocked(fetch)
            } else {
                queuedFetches.append(fetch)
            }
            return true
        }
    }

    /// Starts `fetch` as an in-flight task. Call with `stateLock` held.
    private func startFetchLocked(_ fetch: PendingFetch) {
        runningFetches += 1
        nextInFlightID += 1
        let taskID = nextInFlightID
        let fetcher = self.fetcher
        let boundary = self.boundary
        // The task finishes itself; it waits for the lock held here, so the
        // entry exists before the removal runs.
        let task = Task { [weak self] in
            let result = boundary.redactFetch(await fetcher.fetch(requestJSON: fetch.requestJSON))
            guard let self else { return }
            self.thread.perform { [weak self] in self?.resolveCall(fetch.callID, result) }
            self.fetchFinished(taskID)
        }
        inFlight[taskID] = InFlightWork(task: task, evalID: fetch.evalID, isFetch: true)
    }

    /// Frees the finished fetch's slot and starts the oldest queued one.
    private func fetchFinished(_ taskID: Int) {
        stateLock.withLock {
            // close() already dropped every entry and the queue.
            guard inFlight.removeValue(forKey: taskID) != nil else { return }
            runningFetches -= 1
            if !closed, !queuedFetches.isEmpty {
                startFetchLocked(queuedFetches.removeFirst())
            }
        }
    }

    /// Asks the runtime to drop cell `evalID` if it is still running
    /// (`__cmuxReplCancel`); a cell that already ended is left alone.
    private func cancelRunningCell(_ message: String, evalID: Int) {
        guard let context, !isClosedNow, let cancel = entryPoints?.cancel else { return }
        enter(context) { _ = cancel.call(withArguments: [message, evalID]) }
    }

    /// Runs `body`, which calls into `context`, as one watchdog run under
    /// the cell running now, and clears the exception it left. A cell that
    /// is current but has not begun on the thread is not running: a
    /// callback queued ahead of it is not its work, so the callback budget
    /// bounds it instead of that cell's timeout.
    private func enter(_ context: JSContext, _ body: () -> Void) {
        watchdog.absorbTermination(in: context)
        let running = stateLock.withLock { currentEval.flatMap { $0.hasBegun ? $0.id : nil } }
        watchdog.run(evalID: running, body)
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
        let task = Task { [weak self] in
            await body()
            guard let self else { return }
            self.stateLock.withLock { _ = self.inFlight.removeValue(forKey: taskID) }
        }
        inFlight[taskID] = InFlightWork(task: task, evalID: nil, isFetch: false)
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
        state.markBegun()
        if let cwd, cwd != fileSystem.sandbox.root {
            var sandbox = BrowserReplFileSandbox(root: cwd)
            sandbox.inheritReadableFiles(from: fileSystem.sandbox)
            fileSystem = BrowserReplFileSystem(sandbox: sandbox, temporaryDirectory: fileSystem.temporaryRoot)
            // The runtime removes the `__cmuxNative` global before agent code
            // runs; the session keeps its own reference.
            nativeHost?.setObject(cwd, forKeyedSubscript: "cwd" as NSString)
        }

        // Loading the runtime and the cell's first turn are one run of
        // this cell: its timeout bounds them.
        watchdog.run(evalID: state.id) {
            startEval(state, code: code, maxOutput: maxOutput)
        }
    }

    private func startEval(_ state: EvalState, code: String, maxOutput: Int?) {
        guard let context = ensureContext() else {
            finish(state, error: loadError ?? "Error: browser REPL runtime failed to load")
            return
        }
        guard let evalFunction = entryPoints?.evaluate else {
            finish(state, error: "Error: browser REPL runtime is not installed (missing __cmuxReplEval)")
            return
        }

        watchdog.absorbTermination(in: context)
        context.exception = nil
        // The runtime's options argument: `{ "evalId": id, "maxOutput": characters }`;
        // the id lets a timeout cancel exactly this cell.
        let options = maxOutput.map { "{\"evalId\":\(state.id),\"maxOutput\":\(max(0, $0))}" } ?? "{\"evalId\":\(state.id)}"
        let arguments: [Any] = [code, options]
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
        if let formatter = entryPoints?.formatError,
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
        // The app calls the runtime through these; a cell must not (it
        // could start work no cell owns), so they leave the global object.
        guard let entryPoints = takeEntryPoints(from: context) else { return nil }
        self.entryPoints = entryPoints
        self.context = context
        driver.attach { [weak self] name, payload in
            self?.deliverEvent(name: name, payloadJSON: payload)
        }
        return context
    }

    /// The functions the app calls in the runtime (driver-protocol.md,
    /// "Native host contract").
    private struct EntryPoints {
        let evaluate: JSValue
        let cancel: JSValue?
        let onResult: JSValue?
        let onTimer: JSValue?
        let onEvent: JSValue?
        let formatError: JSValue?
    }

    /// Takes the runtime's entry points off the global object, or sets
    /// `loadError` when `__cmuxReplEval` is missing or one cannot be removed.
    private func takeEntryPoints(from context: JSContext) -> EntryPoints? {
        let global = context.globalObject
        var failed: String?
        func take(_ name: String) -> JSValue? {
            guard let value = global?.objectForKeyedSubscript(name), !value.isUndefined else { return nil }
            global?.deleteProperty(name)
            if global?.hasProperty(name) != false { failed = name }
            return value
        }
        let evaluate = take("__cmuxReplEval")
        let entryPoints = evaluate.map { evaluate in
            EntryPoints(
                evaluate: evaluate,
                cancel: take("__cmuxReplCancel"),
                onResult: take("__cmuxHostOnResult"),
                onTimer: take("__cmuxHostOnTimer"),
                onEvent: take("__cmuxHostOnEvent"),
                formatError: take("__cmuxFormatError")
            )
        }
        context.exception = nil
        if let failed {
            loadError = "Error: browser REPL runtime failed to load: its entry point \(failed) could not be removed from the global object"
            return nil
        }
        guard let entryPoints else {
            loadError = "Error: browser REPL runtime is not installed (missing __cmuxReplEval)"
            return nil
        }
        return entryPoints
    }

    private func installNativeHost(in context: JSContext) {
        guard let native = JSValue(newObjectIn: context) else { return }
        native.setObject(1, forKeyedSubscript: "version" as NSString)
        native.setObject(id, forKeyedSubscript: "sessionId" as NSString)
        native.setObject(fileSystem.sandbox.root, forKeyedSubscript: "cwd" as NSString)
        native.setObject(driver.capabilities, forKeyedSubscript: "capabilities" as NSString)
        native.setObject(privateTemporaryDirectory, forKeyedSubscript: "tmpdir" as NSString)
        native.setObject(homeDirectory, forKeyedSubscript: "homedir" as NSString)

        let print: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] level, text in
            guard let self, let state = self.stateLock.withLock({ self.currentEval }) else { return }
            state.append(BrowserReplOutputLine(
                level: level?.toString() ?? "log",
                text: self.boundary.redact(text?.toString() ?? "")
            ))
        }
        let setTimer: @convention(block) (JSValue?, JSValue?, JSValue?) -> Bool = { [weak self] id, delay, repeating in
            guard let self, let id = id?.toInt32() else { return false }
            let duration = Duration.milliseconds(BrowserReplSession.timerDelayMilliseconds(delay?.toDouble()))
            return self.scheduler.schedule(id: Int(id), after: duration, repeating: repeating?.toBool() ?? false)
        }
        let clearTimer: @convention(block) (JSValue?) -> Void = { [weak self] id in
            guard let self, let id = id?.toInt32() else { return }
            self.scheduler.cancel(id: Int(id))
        }
        let driverCall: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] callID, method, params in
            guard let self, let callID = callID?.toInt32() else { return }
            let methodName = method?.toString() ?? ""
            let raw = params.flatMap { $0.isString ? $0.toString() : nil } ?? "{}"
            let boundary = self.boundary
            let paramsJSON: String
            switch boundary.prepare(method: methodName, paramsJSON: raw) {
            case .success(let prepared): paramsJSON = prepared
            case .failure(let error):
                self.resolveCall(Int(callID), .failure(boundary.redact(error)))
                return
            }
            let driver = self.driver
            let started = self.track { [weak self] in
                let result = boundary.redact(method: methodName, await driver.call(method: methodName, paramsJSON: paramsJSON))
                self?.thread.perform { self?.resolveCall(Int(callID), result) }
            }
            if !started { self.resolveCall(Int(callID), .failure(Self.closedError)) }
        }
        let fetch: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] callID, request in
            guard let self, let callID = callID?.toInt32() else { return }
            if !self.startOrQueueFetch(callID: Int(callID), requestJSON: request?.toString() ?? "{}") {
                self.resolveCall(Int(callID), .failure(Self.closedError))
            }
        }
        let fs: @convention(block) (JSValue?, JSValue?) -> String = { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"EINVAL","message":"closed"}}"# }
            let op = operation?.toString() ?? ""
            var args = JSONSerialization.browserReplObject(arguments?.toString() ?? "{}")
            // Text the runtime writes (output spill files, traces, any file)
            // is redacted like output.
            if op == "writeFile", let base64 = args["base64"] as? String {
                args["base64"] = self.boundary.redactFileContents(base64)
            }
            let result = self.fileSystem.perform(op, arguments: args)
            switch result {
            case .success(var value):
                // So is a file read back (a secrets file, a page's download),
                // text or binary.
                if op == "readFile", let base64 = value as? String {
                    value = self.boundary.redactFileContents(base64)
                }
                return JSONSerialization.browserReplString(["ok": value]) ?? #"{"ok":null}"#
            case .failure(let error):
                return JSONSerialization.browserReplString(["error": ["code": error.code, "message": error.message]])
                    ?? #"{"error":{"code":"EIO","message":"error"}}"#
            }
        }
        let secrets: @convention(block) (JSValue?, JSValue?) -> String = { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"closed","message":"closed"}}"# }
            let op = operation?.toString() ?? ""
            var args = JSONSerialization.browserReplObject(arguments?.toString() ?? "{}")
            // secrets.load(path) reads the file here, so its values never
            // reach JavaScript.
            if op == "load", let path = args["path"] as? String {
                switch self.fileSystem.perform("readFile", arguments: ["path": path]) {
                case .failure(let error):
                    return Self.hostResult(.failure(BrowserReplDriverError(code: error.code, message: "secrets.load: \(error.message)")))
                case .success(let base64):
                    guard let data = Data(base64Encoded: base64 as? String ?? ""),
                          let object = try? JSONSerialization.jsonObject(with: data) else {
                        return Self.hostResult(.failure(BrowserReplDriverError(code: "invalid", message: "secrets.load: \(path) is not JSON")))
                    }
                    args["object"] = object
                }
            }
            return Self.hostResult(self.boundary.secretsOperation(op, args))
        }
        let policy: @convention(block) (JSValue?, JSValue?) -> String = { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"closed","message":"closed"}}"# }
            let (result, updated) = self.boundary.policyOperation(
                operation?.toString() ?? "",
                JSONSerialization.browserReplObject(arguments?.toString() ?? "{}")
            )
            if let updated { self.driver.setDomainPolicy(updated) }
            return Self.hostResult(result)
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
        native.setObject(unsafeBitCast(secrets, to: AnyObject.self), forKeyedSubscript: "secrets" as NSString)
        native.setObject(unsafeBitCast(policy, to: AnyObject.self), forKeyedSubscript: "policy" as NSString)
        context.setObject(native, forKeyedSubscript: "__cmuxNative" as NSString)
        nativeHost = native
    }

    private static let closedError = BrowserReplDriverError(code: "closed", message: "the REPL session was closed")

    /// `{"ok": value}` or `{"error": {code, message}}`, as the host's
    /// synchronous functions return.
    private static func hostResult(_ result: Result<Any, BrowserReplDriverError>) -> String {
        switch result {
        case .success(let value):
            return JSONSerialization.browserReplString(["ok": value]) ?? #"{"ok":null}"#
        case .failure(let error):
            return JSONSerialization.browserReplString(["error": ["code": error.code, "message": error.message]])
                ?? #"{"error":{"code":"invalid","message":"error"}}"#
        }
    }

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
        guard let context, !isClosedNow, let resolve = entryPoints?.onResult else { return }
        enter(context) {
            switch result {
            case .success(let json):
                resolve.call(withArguments: [callID, NSNull(), json])
            case .failure(let error):
                resolve.call(withArguments: [callID, error.json, NSNull()])
            }
        }
    }

    /// Runs timer `id`'s callback on the thread, as the scheduler does once
    /// it elapsed (internal for tests).
    func fireTimer(_ id: Int) {
        thread.perform { [weak self] in
            guard let self else { return }
            // The timer counts as pending until its callback has run.
            defer { self.scheduler.delivered(id: id) }
            guard let context = self.context, !self.isClosedNow, let handler = self.entryPoints?.onTimer else { return }
            self.enter(context) { _ = handler.call(withArguments: [id]) }
        }
    }

    private func deliverEvent(name: String, payloadJSON: String) {
        thread.perform { [weak self] in
            guard let self else { return }
            if name == "download.finished",
               let path = JSONSerialization.browserReplObject(payloadJSON)["path"] as? String {
                self.fileSystem.sandbox.allowReading(path)
            }
            guard let context = self.context, !self.isClosedNow, let handler = self.entryPoints?.onEvent else { return }
            let payload = self.boundary.redactJSON(payloadJSON)
            self.enter(context) { _ = handler.call(withArguments: [name, payload]) }
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
