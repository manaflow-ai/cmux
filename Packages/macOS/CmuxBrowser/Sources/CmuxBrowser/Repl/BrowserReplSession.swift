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
    /// Where page events are masked before they go to `thread`, in the
    /// order they arrived, so a large event's redaction never holds the
    /// JavaScript thread. Driver call results pass through it on their way
    /// to `thread` too, so an event the driver sent before a call returned
    /// still reaches the runtime before that call's result.
    let eventQueue: DispatchQueue
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
    /// Fetches started and not yet delivered to the runtime, at most
    /// `maxOpenFetches`.
    private var openFetches = 0
    /// The open fetches still waiting for their response's headers, at
    /// most `maxConcurrentFetches`; a fetch leaves this set when its
    /// headers arrive, so a body that never ends holds no slot here.
    private var requestPhaseFetches: Set<Int> = []
    /// Fetches waiting for a slot, oldest first, at most `maxQueuedFetches`.
    private var queuedFetches: [PendingFetch] = []
    /// Driver calls running now, at most `maxConcurrentDriverCalls`.
    private var runningDriverCalls = 0
    /// Driver calls waiting for a slot, oldest first, at most `maxQueuedDriverCalls`.
    private var queuedDriverCalls: [PendingDriverCall] = []
    /// Request bytes the queued and running driver calls and fetches hold,
    /// at most `maxHeldRequestBytes`.
    private var heldRequestBytes = 0
    /// The per-session temporary directory created when no cwd was given.
    private let ownedWorkingDirectory: String?
    /// The session's private temporary directory (mode 0700): `os.tmpdir()`
    /// in the REPL, where output spill files go, and the only `fs` root
    /// besides the working directory.
    private let privateTemporaryDirectory: String
    /// That directory, held open since the session made it: spill files and
    /// fs calls go there whatever happens to its path.
    private let privateTemporaryDescriptor: BrowserReplDescriptor?
    private let homeDirectory: String
    /// Where sessions keep private files under the app's temporary
    /// directory (`cmux-browser-repl`) and where the browser puts downloads
    /// (`cmux-downloads`, see `BrowserPanel.tempDir`): a working directory
    /// that is, holds or is inside one of them is refused, except the
    /// session's own directories.
    private let privateStorageRoots: [String]
    /// What the session's fs, and its output spill files, may still write.
    private let writeBudget: BrowserReplWriteBudget

    // JS-thread state.
    private var context: JSContext?
    /// The `__cmuxNative` object; the runtime deletes the global.
    private var nativeHost: JSValue?
    /// The runtime's entry points, taken off the global object once the
    /// runtime loaded, so no cell can call them.
    private var entryPoints: EntryPoints?
    private var loadError: String?
    private var fileSystem: BrowserReplFileSystem
    /// Timer and event callbacks held back while callbacks outside a cell
    /// are in debt with the watchdog's credit, oldest first; they run when
    /// the credit recovers or a cell runs.
    private var heldCallbacks: [HeldCallback] = []
    private var heldEventCount = 0
    private var releaseQueued = false
    private var resumeScheduled = false
    /// The timers the outermost run in progress set, or nil outside one.
    private var timersSetInRun: [Int]?
    /// What the next cell reports about callbacks between cells.
    private var callbacksStopped = 0
    private var callbacksHeld = 0
    private var eventsDropped = 0
    /// The wait for the callback credit to recover; `close()` cancels it.
    private var callbackResume: Task<Void, Never>?

    private enum HeldCallback {
        case timer(Int)
        /// `reserved`: what the event holds of the queued-event budget.
        case event(name: String, payload: String, reserved: Int)
    }

    /// The most page events held back at once; past it the oldest go.
    static let maxHeldEvents = 10_000

    /// The most page events queued for the session's thread or held back
    /// at once, and the most bytes they hold; an event past either is
    /// dropped where it arrives, before it is queued.
    static let maxQueuedEvents = 10_000
    static let maxQueuedEventBytes = 64 << 20

    /// The most bytes one page event's payload may have; a larger one
    /// arrives withheld (`{ targetId, withheld }`), without its content, so
    /// masking secrets in an event never reads more than this.
    static let maxEventPayloadBytes = 1 << 20

    /// Page events queued or held, their bytes, and those dropped where
    /// they arrived since the last cell's notice; guarded by `eventLock`.
    private let eventLock = NSLock()
    private var queuedEvents = 0
    private var queuedEventBytes = 0
    private var eventsDroppedOnArrival = 0

    /// One evaluation's result. It is finished exactly once: by the JS
    /// thread when the cell settles, or from outside it by the timeout or
    /// `close()`, so a wedged JS thread can never strand the caller.
    ///
    /// Past `maxRetainedOutputBytes` of output, whatever reaches the native
    /// print (the runtime's own gate stops well before that), the rest goes
    /// to `<tmpdir>/output-<id>.txt` instead of memory, at most
    /// `maxSpilledOutputBytes` of it and only while the session's fs budget
    /// lasts; output past that is dropped.
    private final class EvalState: @unchecked Sendable {
        let id: Int
        let start = ContinuousClock.now
        private let lock = NSLock()
        private var lines: [BrowserReplOutputLine] = []
        private var continuation: CheckedContinuation<BrowserReplEvalResult, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false
        /// The session's temporary directory, held open, and the spill file's name in it.
        private let spillDirectory: BrowserReplDescriptor?
        private let spillName: String
        /// Where the spill file is, once it was created.
        private var spillPath: String?
        private var retainedBytes = 0
        private var spilledBytes = 0
        /// Bytes written to the spill file.
        private var writtenBytes = 0
        private var spill: FileHandle?
        private var spilling = false
        /// What spill writes take from: the session's fs budget.
        private let spillBudget: BrowserReplWriteBudget

        /// - Parameter spillDirectory: The session's temporary directory,
        ///   held open (nil when it could not be made: output past the
        ///   ceiling is then dropped), with its path when it was made.
        init(
            id: Int,
            spillDirectory: (path: String, descriptor: BrowserReplDescriptor?),
            spillBudget: BrowserReplWriteBudget,
            continuation: CheckedContinuation<BrowserReplEvalResult, Never>
        ) {
            self.id = id
            self.spillBudget = spillBudget
            self.spillDirectory = spillDirectory.descriptor
            self.spillDirectoryPath = spillDirectory.path
            self.spillName = "output-\(id).txt"
            self.continuation = continuation
        }

        private let spillDirectoryPath: String

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
                    // Created in the directory the session made and holds
                    // open, so no link put on its path redirects it; O_EXCL:
                    // never write into a file that is already there.
                    if let spillDirectory {
                        let descriptor = openat(spillDirectory.fd, spillName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        if descriptor >= 0 {
                            spill = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                            // Where the directory is now, if it was moved.
                            spillPath = (spillDirectory.currentPath ?? spillDirectoryPath) + "/" + spillName
                        }
                    }
                    lines.append(BrowserReplOutputLine(
                        level: "info",
                        text: spillPath.map { "# output continues in \($0)" } ?? "# output past this point was dropped"
                    ))
                }
                spilledBytes += size
                guard let file = spill else { return }
                // Past the ceiling, or the session's fs budget, the rest is
                // dropped: the spill file never fills the disk.
                guard writtenBytes + size <= BrowserReplSession.maxSpilledOutputBytes,
                      (try? spillBudget.take(size, syscall: "write", display: spillName, callBytes: 0)) != nil else {
                    try? file.close()
                    spill = nil
                    lines.append(BrowserReplOutputLine(
                        level: "info",
                        text: "# output past \(writtenBytes) bytes in \(spillPath ?? spillName) was dropped: a cell spills at most \(BrowserReplSession.maxSpilledOutputBytes >> 20) MiB, within the session's fs budget"
                    ))
                    return
                }
                writtenBytes += size
                try? file.write(contentsOf: Data((line.text + "\n").utf8))
            }
        }

        /// The note that ends spilled output. Call with `lock` held.
        private func spillSummaryLocked() -> BrowserReplOutputLine? {
            guard spilling else { return nil }
            try? spill?.close()
            spill = nil
            let total = retainedBytes + spilledBytes
            let complete = writtenBytes == spilledBytes
            let destination = spillPath.map { complete ? "full output: \($0)" : "its first \(writtenBytes) bytes past that: \($0)" } ?? "the rest was dropped"
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

    /// The most fetches one session has waiting for their response's
    /// headers at once; later fetches wait in order. A fetch whose headers
    /// arrived leaves its slot, so un-awaited fetches of bodies that never
    /// end (event streams) cannot hold every slot.
    static let maxConcurrentFetches = 16

    /// The most fetches one session has open at once (waiting for headers,
    /// receiving a body, or holding a body the runtime has not taken yet),
    /// which bounds its connections. The bodies they hold at once are
    /// bounded by the fetcher's `BrowserReplFetchBudget`, and each fetch by
    /// `BrowserReplFetcher.resourceTimeout`.
    static let maxOpenFetches = 64

    /// The most fetches one session queues for a slot; past it a fetch fails at once.
    static let maxQueuedFetches = 256

    /// The most driver calls one session runs at once; later ones wait in
    /// order. The snapshot reads up to 256 frames at once (snapshot.js).
    static let maxConcurrentDriverCalls = 256

    /// The most driver calls one session queues; past it a call fails at once.
    static let maxQueuedDriverCalls = 10_000

    /// The most UTF-8 bytes one driver call's parameters may have, 64 MiB
    /// (the fetch and `readFile` limit); a larger call fails where it is
    /// made, before anything holds it.
    static let maxDriverCallParamsBytes = 64 << 20

    /// A file chooser answer carries its files, Base64, up to
    /// ``BrowserReplUploadStaging/maximumBytes`` decoded (1 MiB more for
    /// names and the envelope).
    static let maxFileChooserAnswerBytes = BrowserReplUploadStaging.maximumBytes / 3 * 4 + (1 << 20)

    /// The most bytes of request data (driver call parameters, fetch
    /// requests) one session's waiting and running calls hold at once,
    /// 512 MiB; a call past it fails at once.
    static let maxHeldRequestBytes = 512 << 20

    /// The most timers a session has scheduled, or fired with their callback
    /// not yet run, at once; `setTimer` returns false past it.
    public static let maxPendingTimers = 10_000

    /// The most output, in UTF-8 bytes, one evaluation keeps in memory; the
    /// rest goes to a file in the session's temporary directory.
    static let maxRetainedOutputBytes = 16 << 20

    /// The most output, in UTF-8 bytes, one evaluation writes to its spill
    /// file; the rest is dropped.
    static let maxSpilledOutputBytes = 64 << 20

    /// A tracked task, and the evaluation that was running when it started.
    private struct InFlightWork {
        let task: Task<Void, Never>
        let evalID: Int?
        let isFetch: Bool
        /// The request bytes it holds (``maxHeldRequestBytes``).
        let heldBytes: Int
    }

    /// A fetch the runtime asked for, waiting for a slot or running.
    private struct PendingFetch {
        let callID: Int
        let requestJSON: String
        let evalID: Int?
        /// What it counts against ``maxHeldRequestBytes``.
        var heldBytes: Int { requestJSON.utf8.count }
    }

    /// A driver call the runtime asked for, its params already prepared.
    private struct PendingDriverCall {
        let callID: Int
        let method: String
        let paramsJSON: String
        let evalID: Int?
        /// What it counts against ``maxHeldRequestBytes``.
        var heldBytes: Int { method.utf8.count + paramsJSON.utf8.count }
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
    ///   - maxPendingTimers: The most timers scheduled, or fired with their
    ///     callback not yet run, at once (tests lower it).
    public convenience init(
        id: String,
        cwd: String?,
        bundle: BrowserReplRuntimeBundle,
        driver: any BrowserReplDriver,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock()),
        temporaryDirectory: String? = nil,
        homeDirectory: String? = nil,
        callbackTimeLimit: Duration = BrowserReplSession.defaultCallbackTimeLimit,
        maxPendingTimers: Int = BrowserReplSession.maxPendingTimers
    ) {
        self.init(
            id: id,
            cwd: cwd,
            bundle: bundle,
            driver: driver,
            sleeper: sleeper,
            temporaryDirectory: temporaryDirectory,
            homeDirectory: homeDirectory,
            callbackTimeLimit: callbackTimeLimit,
            maxPendingTimers: maxPendingTimers,
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
    }

    /// - Parameter executionTimeLimitSupported: Whether this JavaScriptCore
    ///   can stop a running script (tests pass false); without it the
    ///   session refuses every cell.
    init(
        id: String,
        cwd: String?,
        bundle: BrowserReplRuntimeBundle,
        driver: any BrowserReplDriver,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock()),
        temporaryDirectory: String? = nil,
        homeDirectory: String? = nil,
        callbackTimeLimit: Duration = BrowserReplSession.defaultCallbackTimeLimit,
        maxPendingTimers: Int = BrowserReplSession.maxPendingTimers,
        executionTimeLimitSupported: Bool
    ) {
        let temporaryRoot = BrowserReplFileSandbox.canonicalize(
            BrowserReplFileSandbox.lexicallyNormalized(temporaryDirectory ?? NSTemporaryDirectory())
        )
        let resolvedCwd: String
        var cwdDescriptor: BrowserReplDescriptor?
        if let cwd {
            resolvedCwd = cwd
            ownedWorkingDirectory = nil
        } else {
            (resolvedCwd, cwdDescriptor) = Self.makeSessionDirectory(id: id, temporaryRoot: temporaryRoot)
            ownedWorkingDirectory = resolvedCwd
        }
        (privateTemporaryDirectory, privateTemporaryDescriptor) = Self.makeSessionDirectory(id: id, temporaryRoot: temporaryRoot, suffix: "-tmp")
        privateStorageRoots = ["cmux-browser-repl", "cmux-downloads"].map { (temporaryRoot == "/" ? "" : temporaryRoot) + "/" + $0 }
        self.id = id
        self.workingDirectory = resolvedCwd
        self.homeDirectory = homeDirectory ?? NSHomeDirectory()
        self.bundle = bundle
        self.driver = driver
        self.boundary = BrowserReplBoundary(typedSecrets: { driver.typedSecretRedaction() })
        self.sleeper = sleeper
        self.thread = BrowserReplJSThread(name: "com.cmux.browser-repl.\(id)")
        self.eventQueue = DispatchQueue(label: "com.cmux.browser-repl.events.\(id)", qos: .userInitiated)
        let watchdog = BrowserReplWatchdog(callbackTimeLimit: callbackTimeLimit, supported: executionTimeLimitSupported)
        self.watchdog = watchdog
        self.fetcher = BrowserReplFetcher(driver: driver)
        let writeBudget = BrowserReplWriteBudget()
        self.writeBudget = writeBudget
        self.fileSystem = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: resolvedCwd),
            temporaryDirectory: privateTemporaryDirectory,
            rootDescriptor: cwdDescriptor,
            temporaryDescriptor: privateTemporaryDescriptor,
            writeBudget: writeBudget,
            // A cell's timeout and close() ask the watchdog to stop the
            // running script; a long fs write or copy stops with it.
            isCancelled: { watchdog.isTerminationRequested }
        )
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock(), maximumTimers: maxPendingTimers) { [weak self] id in
            self?.fireTimer(id)
        }
        let boundary = self.boundary
        fetcher.setBlockReason { url in boundary.blockReason(url) }
        boundary.setFileRoots([fileSystem.sandbox.root] + (fileSystem.temporaryRoot.map { [$0] } ?? []))
        driver.setFileRoots([fileSystem.sandbox.root] + (fileSystem.temporaryRoot.map { [$0] } ?? []))
    }

    /// Creates `<temporaryRoot>/cmux-browser-repl/<id>-<random><suffix>`, a
    /// new directory of the session's own: its working directory when it
    /// was started without a cwd, and its private temporary directory. Both
    /// and their parent are mode 0700: the agent's files never reach another
    /// local user.
    ///
    /// Every step after `temporaryRoot` goes through a held descriptor
    /// (`mkdirat`, `openat` with `O_NOFOLLOW`): a link in place of the parent
    /// is never followed, and the new directory is returned open, so later
    /// use never walks its path again.
    /// - Returns: The directory's path and its descriptor; nil when it could
    ///   not be made (an fs call there then fails, and output past the
    ///   ceiling is dropped).
    private static func makeSessionDirectory(
        id: String,
        temporaryRoot: String,
        suffix: String = ""
    ) -> (path: String, descriptor: BrowserReplDescriptor?) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeID = String(String.UnicodeScalarView(id.unicodeScalars.prefix(64).map { allowed.contains($0) ? $0 : "_" }))
        let parentName = "cmux-browser-repl"
        let parentPath = (temporaryRoot == "/" ? "" : temporaryRoot) + "/" + parentName
        var name = "\(safeID)-\(UUID().uuidString.prefix(8))\(suffix)"
        var rootDescriptor = open(temporaryRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if rootDescriptor < 0, errno == ENOENT {
            try? FileManager.default.createDirectory(atPath: temporaryRoot, withIntermediateDirectories: true)
            rootDescriptor = open(temporaryRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { return (parentPath + "/" + name, nil) }
        let root = BrowserReplDescriptor(rootDescriptor)
        // The umask can only narrow the mode.
        _ = mkdirat(root.fd, parentName, 0o700)
        let parentDescriptor = openat(root.fd, parentName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { return (parentPath + "/" + name, nil) }
        let parent = BrowserReplDescriptor(parentDescriptor)
        // An existing parent must be this user's own directory; one an
        // earlier version made 0755 is narrowed.
        var info = stat()
        guard fstat(parent.fd, &info) == 0, info.st_uid == getuid() else { return (parentPath + "/" + name, nil) }
        if info.st_mode & 0o077 != 0 { fchmod(parent.fd, 0o700) }
        // mkdirat(2) creates the directory itself, never one that already
        // exists, so no other session's directory is ever reused.
        for attempt in 0..<8 {
            if attempt > 0 { name = "\(safeID)-\(UUID().uuidString.prefix(8))\(suffix)" }
            guard mkdirat(parent.fd, name, 0o700) == 0 else { continue }
            let descriptor = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { break }
            return (parentPath + "/" + name, BrowserReplDescriptor(descriptor))
        }
        return (parentPath + "/" + name, nil)
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
        // A new working directory is checked and opened here, once: the cell
        // later moves to the directory held open now, never to whatever its
        // path names by then.
        let pinned: Result<PinnedRoot, PinRefusal>? = cwd.map(pinRoot)
        return await withCheckedContinuation { continuation in
            stateLock.lock()
            lastUsedAt = .now
            var refusal: String?
            if closed {
                refusal = "Error: REPL session '\(id)' is closed"
            } else if case .failure(let reason) = pinned {
                refusal = "Error: \(reason.message)"
            } else if cwd == nil, let reason = rootRejection(workingDirectory) {
                refusal = "Error: \(reason)"
            }
            if let refusal {
                stateLock.unlock()
                continuation.resume(returning: BrowserReplEvalResult(lines: [], error: refusal, durationMilliseconds: 0))
                return
            }
            let previousDirectory = workingDirectory
            if let cwd { workingDirectory = cwd }
            let root = try? pinned?.get()
            nextEvalID += 1
            let state = EvalState(
                id: nextEvalID,
                spillDirectory: (privateTemporaryDirectory, privateTemporaryDescriptor),
                spillBudget: writeBudget,
                continuation: continuation
            )
            currentEval = state
            watchdog.setCurrentEval(state.id)
            let submitted = thread.perform { [self] in
                self.beginEval(state, code: code, cwd: cwd, root: root, previousDirectory: previousDirectory, maxOutput: maxOutput)
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

    /// A new working directory, checked and opened while no REPL `fs.rename`
    /// can run: its canonical path and its directory, held open from then.
    struct PinnedRoot: Sendable {
        let path: String
        /// Nil when the directory does not exist yet (`mkdir -p` makes it,
        /// by a walk from `/` that follows no link).
        let directory: BrowserReplDescriptor?

        /// Whether `path` still names the held directory, with no link on
        /// the way: the driver takes the identity of the directory at
        /// `path` for file navigations, which must be this one.
        var isStillInPlace: Bool {
            guard let directory else { return true }
            guard BrowserReplFileSandbox.canonicalize(BrowserReplFileSandbox.lexicallyNormalized(path)) == path else { return false }
            var held = stat()
            var named = stat()
            return fstat(directory.fd, &held) == 0 && lstat(path, &named) == 0
                && named.st_mode & S_IFMT == S_IFDIR
                && held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }
    }

    struct PinRefusal: Error {
        let message: String
    }

    /// Checks `cwd` as a working directory and opens it, both while no REPL
    /// session can rename an entry (``BrowserReplFileSandbox/pathChangeLock``):
    /// its canonical path is checked (``rootRejection(_:)``) and opened by a
    /// walk from `/` that follows no link, so a link another session renames
    /// in for a checked directory is never adopted, and a link on the way is
    /// refused.
    private func pinRoot(_ cwd: String) -> Result<PinnedRoot, PinRefusal> {
        if let reason = rootRejection(cwd) { return .failure(PinRefusal(message: reason)) }
        return BrowserReplFileSandbox.pathChangeLock.withLock {
            let path = BrowserReplFileSandbox.canonicalize(BrowserReplFileSandbox.lexicallyNormalized(cwd))
            if let reason = rootRejection(path) { return .failure(PinRefusal(message: reason)) }
            let descriptor = BrowserReplRootDirectories.open(path)
            if descriptor >= 0 { return .success(PinnedRoot(path: path, directory: BrowserReplDescriptor(descriptor))) }
            if errno == ENOENT { return .success(PinnedRoot(path: path, directory: nil)) }
            return .failure(PinRefusal(message: errno == ELOOP
                ? "refusing to use '\(cwd)' as the REPL working directory: its path changed to a symbolic link while it was checked. Run the command again from the directory itself"
                : "cannot use '\(cwd)' as the REPL working directory: \(String(cString: strerror(errno)))"))
        }
    }

    /// Why `root` cannot be this session's working directory, or nil: `/`,
    /// the home directory and its parents
    /// (``BrowserReplFileSandbox/rootRejection(_:homeDirectory:)``), and a
    /// directory that is, holds or is inside the sessions' private storage
    /// or the browser's downloads, which fs would reach (another session's
    /// spilled output, captures and downloads), unless it is one of this
    /// session's own directories.
    private func rootRejection(_ root: String) -> String? {
        if let reason = BrowserReplFileSandbox.rootRejection(root, homeDirectory: homeDirectory) { return reason }
        let canonical = BrowserReplFileSandbox.canonicalize(BrowserReplFileSandbox.lexicallyNormalized(root))
        let own = [ownedWorkingDirectory, privateTemporaryDirectory].compactMap { $0 }
        if own.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) { return nil }
        let prefix = canonical == "/" ? "/" : canonical + "/"
        for storage in privateStorageRoots where canonical == storage || storage.hasPrefix(prefix) || canonical.hasPrefix(storage + "/") {
            return "refusing to use '\(root)' as the REPL working directory: fs would reach \(storage), where browser REPL sessions keep their private files and the browser its downloads. "
                + "cd to a project or scratch directory (for example cd \"$(mktemp -d)\") and run the command again"
        }
        return nil
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
        var tasks = inFlight.values.map(\.task)
        if let callbackResume { tasks.append(callbackResume) }
        callbackResume = nil
        inFlight.removeAll()
        queuedFetches.removeAll()
        openFetches = 0
        requestPhaseFetches.removeAll()
        queuedDriverCalls.removeAll()
        runningDriverCalls = 0
        heldRequestBytes = 0
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
        cancelWork(ofEval: state.id)
    }

    /// Cancels the running fetches and driver calls cell `evalID` started
    /// and fails its queued ones.
    private func cancelWork(ofEval evalID: Int) {
        let (tasks, droppedFetches, droppedCalls): ([Task<Void, Never>], [Int], [Int]) = stateLock.withLock {
            let tasks = inFlight.values.filter { $0.evalID == evalID }.map(\.task)
            let fetches = queuedFetches.filter { $0.evalID == evalID }
            queuedFetches.removeAll { $0.evalID == evalID }
            let calls = queuedDriverCalls.filter { $0.evalID == evalID }
            queuedDriverCalls.removeAll { $0.evalID == evalID }
            heldRequestBytes -= fetches.reduce(0) { $0 + $1.heldBytes } + calls.reduce(0) { $0 + $1.heldBytes }
            return (tasks, fetches.map(\.callID), calls.map(\.callID))
        }
        for task in tasks { task.cancel() }
        guard !droppedFetches.isEmpty || !droppedCalls.isEmpty else { return }
        thread.perform { [weak self] in
            for callID in droppedFetches { self?.resolveCall(callID, .failure(Self.cancelledFetchError)) }
            for callID in droppedCalls { self?.resolveCall(callID, .failure(Self.cancelledDriverCallError)) }
        }
    }

    private static let cancelledFetchError = BrowserReplDriverError(
        code: "cancelled",
        message: "fetch: cancelled because the cell that started it timed out"
    )

    private static let cancelledDriverCallError = BrowserReplDriverError(
        code: "cancelled",
        message: "cancelled because the cell that started it timed out"
    )

    /// Runs the driver call now, or queues it while `maxConcurrentDriverCalls`
    /// run. Returns why it was refused (the session is closed, or the queue
    /// is full), or nil. The evaluation running when the runtime asked owns
    /// the call, so its timeout cancels it.
    private func startOrQueueDriverCall(callID: Int, method: String, paramsJSON: String) -> BrowserReplDriverError? {
        stateLock.withLock {
            guard !closed else { return Self.closedError }
            let call = PendingDriverCall(callID: callID, method: method, paramsJSON: paramsJSON, evalID: currentEval?.id)
            if let refusal = admitRequestLocked(bytes: call.heldBytes, what: "browser calls and fetches") { return refusal }
            if queuedDriverCalls.isEmpty, runningDriverCalls < Self.maxConcurrentDriverCalls {
                startDriverCallLocked(call)
            } else if queuedDriverCalls.count < Self.maxQueuedDriverCalls {
                queuedDriverCalls.append(call)
            } else {
                heldRequestBytes -= call.heldBytes
                return BrowserReplDriverError(
                    code: "invalid",
                    message: "\(Self.maxQueuedDriverCalls) browser calls are already waiting for one of the session's \(Self.maxConcurrentDriverCalls) slots; await some before starting more"
                )
            }
            return nil
        }
    }

    /// Starts `call` as an in-flight task. Call with `stateLock` held.
    private func startDriverCallLocked(_ call: PendingDriverCall) {
        runningDriverCalls += 1
        nextInFlightID += 1
        let taskID = nextInFlightID
        let driver = self.driver
        let boundary = self.boundary
        // The task finishes itself; it waits for the lock held here, so the
        // entry exists before the removal runs.
        let task = Task { [weak self] in
            let answer = await driver.call(method: call.method, paramsJSON: call.paramsJSON)
            let result = boundary.redact(method: call.method, boundary.checkCaptureMasks(method: call.method, paramsJSON: call.paramsJSON, answer))
            guard let self else { return }
            // Behind the events the driver sent before it returned.
            self.eventQueue.async { [weak self] in
                guard let self else { return }
                self.thread.perform { [weak self] in self?.resolveCall(call.callID, result) }
            }
            self.driverCallFinished(taskID)
        }
        inFlight[taskID] = InFlightWork(task: task, evalID: call.evalID, isFetch: false, heldBytes: call.heldBytes)
    }

    /// Frees the finished driver call's slot and starts queued ones.
    private func driverCallFinished(_ taskID: Int) {
        stateLock.withLock {
            // close() already dropped every entry and the queue.
            guard let work = inFlight.removeValue(forKey: taskID) else { return }
            heldRequestBytes -= work.heldBytes
            runningDriverCalls -= 1
            while !closed, !queuedDriverCalls.isEmpty, runningDriverCalls < Self.maxConcurrentDriverCalls {
                startDriverCallLocked(queuedDriverCalls.removeFirst())
            }
        }
    }

    /// Runs the fetch now, or queues it while the slots are taken. Returns
    /// why it was refused (the session is closed, or the queue is full), or
    /// nil. The evaluation running when the runtime asked owns the fetch, so
    /// its timeout cancels it.
    private func startOrQueueFetch(callID: Int, requestJSON: String) -> BrowserReplDriverError? {
        stateLock.withLock {
            guard !closed else { return Self.closedError }
            let fetch = PendingFetch(callID: callID, requestJSON: requestJSON, evalID: currentEval?.id)
            if let refusal = admitRequestLocked(bytes: fetch.heldBytes, what: "fetch: browser calls and fetches") { return refusal }
            if queuedFetches.isEmpty, hasFetchSlotLocked {
                startFetchLocked(fetch)
            } else if queuedFetches.count < Self.maxQueuedFetches {
                queuedFetches.append(fetch)
            } else {
                heldRequestBytes -= fetch.heldBytes
                return BrowserReplDriverError(
                    code: "invalid",
                    message: "fetch: \(Self.maxQueuedFetches) fetches are already waiting for one of the session's \(Self.maxConcurrentFetches) fetch slots; await some before starting more"
                )
            }
            return nil
        }
    }

    /// Takes `bytes` of ``maxHeldRequestBytes`` for a call about to wait or
    /// run, or says why it is refused. Call with `stateLock` held.
    private func admitRequestLocked(bytes: Int, what: String) -> BrowserReplDriverError? {
        guard heldRequestBytes + bytes > Self.maxHeldRequestBytes else {
            heldRequestBytes += bytes
            return nil
        }
        return BrowserReplDriverError(
            code: "invalid",
            message: "\(what) waiting or running in this session already hold \(heldRequestBytes >> 20) MiB of parameters, and this one (\(bytes >> 20) MiB) would pass the \(Self.maxHeldRequestBytes >> 20) MiB they may hold at once; await some before starting more"
        )
    }

    /// Whether a fetch can start now. Call with `stateLock` held.
    private var hasFetchSlotLocked: Bool {
        requestPhaseFetches.count < Self.maxConcurrentFetches && openFetches < Self.maxOpenFetches
    }

    /// Starts `fetch` as an in-flight task. Call with `stateLock` held.
    private func startFetchLocked(_ fetch: PendingFetch) {
        nextInFlightID += 1
        let taskID = nextInFlightID
        openFetches += 1
        requestPhaseFetches.insert(taskID)
        let fetcher = self.fetcher
        let boundary = self.boundary
        // The task finishes itself; it waits for the lock held here, so the
        // entry exists before the removal runs. Its slot and the bytes of
        // its body are held until the runtime has the result, so results
        // the busy JS thread has not taken yet stay bounded too.
        let task = Task { [weak self] in
            let (raw, heldBytes) = await fetcher.fetchHoldingBody(requestJSON: fetch.requestJSON) { [weak self] in
                self?.fetchReceivedHeaders(taskID)
            }
            let result = boundary.redactFetch(raw)
            guard let self else {
                fetcher.bodyBudget.release(heldBytes)
                return
            }
            let delivered = self.thread.perform { [weak self] in
                self?.resolveCall(fetch.callID, result)
                fetcher.bodyBudget.release(heldBytes)
                self?.fetchFinished(taskID)
            }
            if !delivered {
                fetcher.bodyBudget.release(heldBytes)
                self.fetchFinished(taskID)
            }
        }
        inFlight[taskID] = InFlightWork(task: task, evalID: fetch.evalID, isFetch: true, heldBytes: fetch.heldBytes)
    }

    /// The fetch's response headers arrived: it leaves its slot.
    private func fetchReceivedHeaders(_ taskID: Int) {
        stateLock.withLock {
            guard requestPhaseFetches.remove(taskID) != nil else { return }
            startQueuedFetchesLocked()
        }
    }

    /// Frees the finished fetch's slot and starts queued ones.
    private func fetchFinished(_ taskID: Int) {
        stateLock.withLock {
            // close() already dropped every entry and the queue.
            guard let work = inFlight.removeValue(forKey: taskID) else { return }
            heldRequestBytes -= work.heldBytes
            openFetches -= 1
            requestPhaseFetches.remove(taskID)
            startQueuedFetchesLocked()
        }
    }

    /// Starts the oldest queued fetches while slots are free. Call with `stateLock` held.
    private func startQueuedFetchesLocked() {
        while !closed, !queuedFetches.isEmpty, hasFetchSlotLocked {
            startFetchLocked(queuedFetches.removeFirst())
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
    ///
    /// When the watchdog's limit ends the run, the timers it set (an
    /// interval re-arming itself, say) are cancelled, and so is `firedTimer`
    /// when it repeats; the next cell reports it.
    private func enter(_ context: JSContext, firedTimer: Int? = nil, _ body: () -> Void) {
        watchdog.absorbTermination(in: context)
        let running = runningEvalID
        let outermost = timersSetInRun == nil
        if outermost {
            timersSetInRun = []
            _ = watchdog.takeLimitTermination()
        }
        watchdog.run(evalID: running, body)
        context.exception = nil
        guard outermost else { return }
        let timers = timersSetInRun ?? []
        timersSetInRun = nil
        if watchdog.takeLimitTermination() {
            callbacksStopped += 1
            for id in timers { scheduler.cancel(id: id) }
            if let firedTimer { scheduler.cancel(id: firedTimer) }
        }
    }

    /// The cell running on the thread now: current and begun.
    private var runningEvalID: Int? {
        stateLock.withLock { currentEval.flatMap { $0.hasBegun ? $0.id : nil } }
    }

    // MARK: - Callbacks between cells

    /// Whether a timer or event callback must wait: one already waits (they
    /// keep their order), or no cell runs and callbacks outside a cell
    /// have used more than their share of the thread.
    private var mustHoldCallback: Bool {
        !heldCallbacks.isEmpty || (runningEvalID == nil && watchdog.isInCallbackDebt)
    }

    /// Holds `callback` back until the credit recovers or a cell runs.
    private func hold(_ callback: HeldCallback) {
        if case .event = callback {
            if heldEventCount >= Self.maxHeldEvents,
               let oldest = heldCallbacks.firstIndex(where: { if case .event = $0 { true } else { false } }) {
                if case .event(_, _, let reserved) = heldCallbacks.remove(at: oldest) { releaseEvent(reserved) }
                heldEventCount -= 1
                eventsDropped += 1
            }
            heldEventCount += 1
        }
        heldCallbacks.append(callback)
        callbacksHeld += 1
        if runningEvalID != nil {
            queueHeldRelease()
        } else {
            scheduleCallbackResume()
        }
    }

    /// Runs the oldest held callback in its own thread block, so a cell
    /// submitted meanwhile runs in turn.
    private func queueHeldRelease() {
        guard !releaseQueued, !heldCallbacks.isEmpty else { return }
        releaseQueued = true
        let queued = thread.perform { [weak self] in
            guard let self else { return }
            self.releaseQueued = false
            self.releaseOneHeldCallback()
        }
        if !queued { releaseQueued = false }
    }

    private func releaseOneHeldCallback() {
        guard !heldCallbacks.isEmpty else { return }
        guard let context, !isClosedNow, let entryPoints else {
            for case .event(_, _, let reserved) in heldCallbacks { releaseEvent(reserved) }
            heldCallbacks.removeAll()
            heldEventCount = 0
            return
        }
        if runningEvalID == nil, watchdog.isInCallbackDebt {
            scheduleCallbackResume()
            return
        }
        switch heldCallbacks.removeFirst() {
        case .timer(let id):
            defer { scheduler.delivered(id: id) }
            if let handler = entryPoints.onTimer {
                enter(context, firedTimer: id) { _ = handler.call(withArguments: [id]) }
            }
        case .event(let name, let payload, let reserved):
            heldEventCount -= 1
            releaseEvent(reserved)
            if let handler = entryPoints.onEvent {
                enter(context) { _ = handler.call(withArguments: [name, payload]) }
            }
        }
        queueHeldRelease()
    }

    /// Releases held callbacks once the credit is out of debt.
    private func scheduleCallbackResume() {
        guard !resumeScheduled else { return }
        resumeScheduled = true
        let wait = watchdog.timeUntilCredit
        let sleeper = self.sleeper
        let task = Task { [weak self] in
            try? await sleeper.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.thread.perform { [weak self] in
                guard let self else { return }
                self.resumeScheduled = false
                self.releaseOneHeldCallback()
            }
        }
        let closedNow: Bool = stateLock.withLock {
            if closed { return true }
            callbackResume = task
            return false
        }
        if closedNow { task.cancel() }
    }

    /// Output lines that tell the cell starting now about callbacks that
    /// ran between cells and were stopped or held back.
    private func takeCallbackNotices() -> [BrowserReplOutputLine] {
        var lines: [String] = []
        let limit = Self.describe(watchdog.callbackTimeLimit)
        if callbacksStopped == 1 {
            lines.append("cmux browser repl: a timer or event callback that ran between cells went past \(limit) and was stopped; the timers it set were cancelled")
        } else if callbacksStopped > 1 {
            lines.append("cmux browser repl: \(callbacksStopped) timer or event callbacks that ran between cells went past \(limit) and were stopped; the timers they set were cancelled")
        }
        if callbacksHeld > 0 {
            lines.append("cmux browser repl: \(callbacksHeld) timer or event callbacks between cells waited, because callbacks outside a cell may use at most 10% of the session's JavaScript time (and \(limit) at once); those still waiting run during this cell")
        }
        let droppedOnArrival = eventLock.withLock {
            defer { eventsDroppedOnArrival = 0 }
            return eventsDroppedOnArrival
        }
        if eventsDropped > 0 {
            lines.append("cmux browser repl: \(eventsDropped) page events were dropped because \(Self.maxHeldEvents) were already waiting")
        }
        if droppedOnArrival > 0 {
            lines.append("cmux browser repl: \(droppedOnArrival) page events were dropped because \(Self.maxQueuedEvents) events or \(Self.maxQueuedEventBytes >> 20) MiB of them were already waiting for the session's thread")
        }
        callbacksStopped = 0
        callbacksHeld = 0
        eventsDropped = 0
        return lines.map { BrowserReplOutputLine(level: "error", text: $0) }
    }

    /// `10 s`, `1.5 s` or `250 ms`.
    private static func describe(_ duration: Duration) -> String {
        let milliseconds = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        if milliseconds >= 1000, milliseconds % 1000 == 0 { return "\(milliseconds / 1000) s" }
        return milliseconds >= 1000 ? "\(Double(milliseconds) / 1000) s" : "\(milliseconds) ms"
    }

    // MARK: - JS thread

    private func beginEval(
        _ state: EvalState,
        code: String,
        cwd: String?,
        root: PinnedRoot?,
        previousDirectory: String,
        maxOutput: Int?
    ) {
        // A timeout or close() may have finished the evaluation before the
        // thread reached it.
        guard !state.isFinished, !isClosedNow else { return }
        state.markBegun()
        for line in takeCallbackNotices() { state.append(line) }
        // Callbacks held back between cells run during this cell, in order.
        queueHeldRelease()
        if let cwd, let root, root.path != fileSystem.sandbox.root {
            // The fs moves to the directory checked and held when the cell
            // was submitted. The browser's file roots are published by path
            // with the identity of the directory there now, so that must
            // still be the held one; nothing renames meanwhile.
            let moved: Bool = BrowserReplFileSandbox.pathChangeLock.withLock {
                guard root.isStillInPlace else { return false }
                var sandbox = BrowserReplFileSandbox(root: root.path)
                sandbox.inheritReadableFiles(from: fileSystem.sandbox)
                // The temporary root stays the directory held since the session began.
                fileSystem = BrowserReplFileSystem(
                    sandbox: sandbox,
                    temporaryDirectory: fileSystem.temporaryRoot,
                    rootDescriptor: root.directory,
                    temporaryDescriptor: fileSystem.temporaryRoot.flatMap { fileSystem.rootDirectories.descriptor(at: 1, for: $0) },
                    writeBudget: fileSystem.writeBudget,
                    isCancelled: fileSystem.isCancelled
                )
                boundary.setFileRoots([fileSystem.sandbox.root] + (fileSystem.temporaryRoot.map { [$0] } ?? []))
                driver.setFileRoots([fileSystem.sandbox.root] + (fileSystem.temporaryRoot.map { [$0] } ?? []))
                return true
            }
            guard moved else {
                stateLock.withLock { workingDirectory = previousDirectory }
                finish(state, error: "Error: refusing to use '\(cwd)' as the REPL working directory: it was moved or replaced since the command was checked. Run the command again from the directory itself")
                return
            }
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
        // Without the watchdog nothing could stop a looping script: the
        // cell's timeout, reset and close() would all wait behind it.
        guard watchdog.install(on: context) else {
            loadError = "Error: the browser REPL does not run cells here: this macOS's JavaScriptCore cannot stop a running script (JSContextGroupSetExecutionTimeLimit is missing), so a looping cell would hold the session for good"
            return nil
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
            guard self.scheduler.schedule(id: Int(id), after: duration, repeating: repeating?.toBool() ?? false) else { return false }
            self.timersSetInRun?.append(Int(id))
            return true
        }
        let clearTimer: @convention(block) (JSValue?) -> Void = { [weak self] id in
            guard let self, let id = id?.toInt32() else { return }
            self.scheduler.cancel(id: Int(id))
        }
        let driverCall: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] callID, method, params in
            guard let self, let callID = callID?.toInt32() else { return }
            let methodName = method?.toString() ?? ""
            let raw = params.flatMap { $0.isString ? $0.toString() : nil } ?? "{}"
            // An oversized call is refused before it is parsed or waits.
            let limit = methodName == "filechooser.respond" ? Self.maxFileChooserAnswerBytes : Self.maxDriverCallParamsBytes
            guard raw.utf8.count <= limit else {
                self.resolveCall(Int(callID), .failure(BrowserReplDriverError(
                    code: "invalid",
                    message: "\(methodName): its parameters are \(raw.utf8.count >> 20) MiB, past the \(limit >> 20) MiB one browser call may carry"
                )))
                return
            }
            let boundary = self.boundary
            let paramsJSON: String
            switch boundary.prepare(method: methodName, paramsJSON: raw) {
            case .success(let prepared): paramsJSON = prepared
            case .failure(let error):
                self.resolveCall(Int(callID), .failure(boundary.redact(error)))
                return
            }
            // A file chooser answer's files are staged on disk until the
            // session ends, so they count against its write budget.
            if methodName == "filechooser.respond" {
                do {
                    try self.writeBudget.takeFileChooserAnswer(JSONSerialization.browserReplObject(paramsJSON))
                } catch let error as BrowserReplFileSystemError {
                    self.resolveCall(Int(callID), .failure(BrowserReplDriverError(code: "invalid", message: "filechooser: \(error.message)")))
                    return
                } catch {
                    self.resolveCall(Int(callID), .failure(BrowserReplDriverError(code: "invalid", message: "filechooser: \(error)")))
                    return
                }
            }
            if let refusal = self.startOrQueueDriverCall(callID: Int(callID), method: methodName, paramsJSON: paramsJSON) {
                self.resolveCall(Int(callID), .failure(refusal))
            }
        }
        let fetch: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] callID, request in
            guard let self, let callID = callID?.toInt32() else { return }
            let requestJSON = request?.toString() ?? "{}"
            // An oversized body is refused before it waits in the queue.
            if let refusal = BrowserReplFetcher.oversizedRequest(requestJSON) {
                self.resolveCall(Int(callID), .failure(refusal))
                return
            }
            if let refusal = self.startOrQueueFetch(callID: Int(callID), requestJSON: requestJSON) {
                self.resolveCall(Int(callID), .failure(refusal))
            }
        }
        let fs: @convention(block) (JSValue?, JSValue?) -> String = { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"EINVAL","message":"closed"}}"# }
            let op = operation?.toString() ?? ""
            var args = JSONSerialization.browserReplObject(arguments?.toString() ?? "{}")
            // Text the runtime writes (output spill files, traces, any file)
            // is redacted like output.
            func failure(_ code: String, _ message: String) -> String {
                JSONSerialization.browserReplString(["error": ["code": code, "message": message]])
                    ?? #"{"error":{"code":"EIO","message":"error"}}"#
            }
            if op == "writeFile", let base64 = args["base64"] as? String {
                // Past one call's limit it is refused before it is decoded
                // and scanned (the least it can decode to, less padding).
                let decodedAtLeast = max(0, base64.utf8.count / 4 * 3 - 2)
                do {
                    try self.fileSystem.writeBudget.checkCall(decodedAtLeast, syscall: "write", display: args["path"] as? String ?? "")
                } catch {
                    let refusal = error as? BrowserReplFileSystemError
                    return failure(refusal?.code ?? "EFBIG", refusal?.message ?? "\(error)")
                }
                do {
                    args["base64"] = try self.boundary.redactFileContents(base64)
                } catch {
                    return failure("EINVAL", "writeFile: \(BrowserReplSecretStore.limitMessage(Data(base64Encoded: base64)?.count ?? 0))")
                }
            }
            let result = self.fileSystem.perform(op, arguments: args)
            switch result {
            case .success(var value):
                // So is a file read back (a secrets file, a page's download),
                // text or binary.
                if op == "readFile", let base64 = value as? String {
                    do {
                        value = try self.boundary.redactFileContents(base64)
                    } catch {
                        return failure("EINVAL", "readFile: \(BrowserReplSecretStore.limitMessage(Data(base64Encoded: base64)?.count ?? 0))")
                    }
                }
                return JSONSerialization.browserReplString(["ok": value]) ?? #"{"ok":null}"#
            case .failure(let error):
                return failure(error.code, error.message)
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
            guard let context = self.context, !self.isClosedNow, let handler = self.entryPoints?.onTimer else {
                self.scheduler.delivered(id: id)
                return
            }
            // A held timer stays pending until its callback has run.
            if self.mustHoldCallback {
                self.hold(.timer(id))
                return
            }
            defer { self.scheduler.delivered(id: id) }
            self.enter(context, firedTimer: id) { _ = handler.call(withArguments: [id]) }
        }
    }

    /// Queues a page event for the session's thread. Past
    /// `maxQueuedEvents` events or `maxQueuedEventBytes` bytes queued or
    /// held, it is dropped here, before anything holds it, and the next
    /// cell says so; a finished download still becomes readable. Secrets
    /// are masked on `eventQueue`, off the JavaScript thread, and an event
    /// past `maxEventPayloadBytes` is withheld instead.
    private func deliverEvent(name: String, payloadJSON: String) {
        let reserved = name.utf8.count + payloadJSON.utf8.count
        let admitted: Bool = eventLock.withLock {
            guard queuedEvents < Self.maxQueuedEvents, queuedEventBytes + reserved <= Self.maxQueuedEventBytes else {
                eventsDroppedOnArrival += 1
                return false
            }
            queuedEvents += 1
            queuedEventBytes += reserved
            return true
        }
        let downloadPath = name == "download.finished"
            ? JSONSerialization.browserReplObject(payloadJSON)["path"] as? String
            : nil
        guard admitted else {
            if let downloadPath {
                thread.perform { [weak self] in self?.fileSystem.sandbox.allowReading(downloadPath) }
            }
            return
        }
        eventQueue.async { [weak self] in
            guard let self else { return }
            let (payload, charged) = self.chargeMaskedEvent(name: name, raw: payloadJSON, reserved: reserved)
            let queued = self.thread.perform { [weak self] in
                guard let self else { return }
                if let downloadPath { self.fileSystem.sandbox.allowReading(downloadPath) }
                guard let context = self.context, !self.isClosedNow, let handler = self.entryPoints?.onEvent else {
                    self.releaseEvent(charged)
                    return
                }
                if self.mustHoldCallback {
                    self.hold(.event(name: name, payload: payload, reserved: charged))
                    return
                }
                self.releaseEvent(charged)
                self.enter(context) { _ = handler.call(withArguments: [name, payload]) }
            }
            if !queued { self.releaseEvent(charged) }
        }
    }

    /// The payload of an admitted event as JavaScript will see it, and the
    /// bytes it now holds of `maxQueuedEventBytes`: masking can make it
    /// longer than the raw bytes it was admitted with (`reserved`), and one
    /// that would pass the budget masked arrives withheld instead.
    private func chargeMaskedEvent(name: String, raw: String, reserved: Int) -> (payload: String, reserved: Int) {
        let masked = eventPayloadForJavaScript(name: name, raw)
        let size = name.utf8.count + masked.utf8.count
        let fits: Bool = eventLock.withLock {
            guard queuedEventBytes - reserved + size > Self.maxQueuedEventBytes else {
                queuedEventBytes += size - reserved
                return true
            }
            return false
        }
        if fits { return (masked, size) }
        let reason = "this \(name) event is \(masked.utf8.count) bytes with secrets masked, and the page events waiting for the session's thread already hold close to \(Self.maxQueuedEventBytes >> 20) MiB, so its content was withheld"
        let withheld = withheldEventPayload(raw, reason: reason)
        let withheldSize = name.utf8.count + withheld.utf8.count
        eventLock.withLock { queuedEventBytes += withheldSize - reserved }
        return (withheld, withheldSize)
    }

    /// A page event's payload as JavaScript may see it, with secrets
    /// masked. One past `maxEventPayloadBytes`, or that masking would grow
    /// past the redaction limit, arrives as `{ targetId, withheld }`: the
    /// tab it names (masked too), and why its content is not there.
    private func eventPayloadForJavaScript(name: String, _ payloadJSON: String) -> String {
        let size = payloadJSON.utf8.count
        let reason: String
        if size > Self.maxEventPayloadBytes {
            reason = "this \(name) event is \(size) bytes, past the \(Self.maxEventPayloadBytes >> 20) MiB a page event may carry, so its content was withheld"
        } else if let redacted = try? boundary.redactJSON(payloadJSON) {
            return redacted
        } else {
            reason = BrowserReplSecretStore.limitMessage(size)
        }
        return withheldEventPayload(payloadJSON, reason: reason)
    }

    /// `{ targetId, withheld }`: the tab the event names (masked), and why
    /// its content is not there.
    private func withheldEventPayload(_ payloadJSON: String, reason: String) -> String {
        var withheld: [String: Any] = ["withheld": reason]
        if let targetId = JSONSerialization.browserReplObject(payloadJSON)["targetId"] as? String, targetId.utf8.count <= 256 {
            withheld["targetId"] = boundary.redact(targetId)
        }
        return JSONSerialization.browserReplString(withheld) ?? "{}"
    }

    /// An event left the queue (delivered or dropped): its budget is free.
    private func releaseEvent(_ reserved: Int) {
        eventLock.withLock {
            queuedEvents -= 1
            queuedEventBytes -= reserved
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
