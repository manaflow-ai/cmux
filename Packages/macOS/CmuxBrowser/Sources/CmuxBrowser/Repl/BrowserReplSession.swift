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

extension BrowserReplOutputLine {
    /// The levels a line may have; agent code reaches the native print
    /// with any value, which prints as `log` unless it is one of these.
    static let levels: Set<String> = ["log", "info", "warn", "error", "debug"]

    /// `value` when it is a string of ``levels``, else `log`. A string is
    /// measured before it is copied out of JavaScript, so a large one is
    /// never copied.
    static func level(of value: JSValue?) -> String {
        guard let value, value.isString,
              let length = value.forProperty("length")?.toInt32(), length <= 5,
              let level = value.toString(), levels.contains(level) else { return "log" }
        return level
    }

    /// The bytes a kept line holds: its text and level, the newline it
    /// prints with, and the line itself, so many short lines cost what
    /// they hold.
    var retainedBytes: Int {
        text.utf8.count + level.utf8.count + 1 + MemoryLayout<BrowserReplOutputLine>.stride
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

    /// The longest timeout a cell may ask for, 10 minutes: a running cell
    /// holds the session's JavaScript thread until it ends or times out.
    public static let maximumTimeout: Duration = .seconds(600)

    /// Default limit for JavaScript that runs outside a cell.
    public static let defaultCallbackTimeLimit: Duration = .seconds(10)

    /// The most cells waiting for the running one (callers that share a
    /// named session); one more is refused at once.
    public static let maxWaitingCells = BrowserReplResourceLimits.standard[.waitingCells]

    /// The most source, in UTF-8 bytes, the waiting cells hold together;
    /// a cell that would take them past it is refused at once.
    public static let maxWaitingSourceBytes = BrowserReplResourceLimits.standard[.waitingCellSourceBytes]

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
    /// What the session holds, by resource, against its limits (internal
    /// for tests): every holder below reserves here.
    let ledger: BrowserReplResourceLedger
    private let gate: BrowserReplEvalGate
    private var scheduler: BrowserReplTimerScheduler<ContinuousClock>!
    private let watchdog: BrowserReplWatchdog

    // Lifecycle state, guarded by `stateLock`. Submitting work to `thread`
    // happens under the same lock, so `close()` and `evaluate()` see one
    // order: an evaluation either reaches the thread before close's cleanup
    // or sees `closed`.
    private let stateLock = NSLock()
    private var closed = false
    /// Set when the session ended by itself (``endedReason``).
    private var endReason: String?
    /// Lines the next cell prints first (``noteBeforeNextCell(_:)``).
    private var notesBeforeNextCell: [String] = []
    private var lastUsedAt = ContinuousClock.now
    private var workingDirectory: String
    private var currentEval: EvalState?
    private var nextEvalID = 0
    /// Driver calls and fetches in flight; `close()` cancels them, and a
    /// cell's timeout cancels the fetches it started. Each holds its slot
    /// (``BrowserReplResource/runningDriverCalls`` or
    /// ``BrowserReplResource/openFetches``), its request bytes and its
    /// result's bytes in the ledger until the runtime has its result.
    private var inFlight: [Int: InFlightWork] = [:]
    private var nextInFlightID = 0
    /// The open fetches still waiting for their response's headers
    /// (``BrowserReplResource/requestPhaseFetches``); a fetch leaves this
    /// set when its headers arrive, so a body that never ends holds no
    /// slot here.
    private var requestPhaseFetches: Set<Int> = []
    /// Fetches waiting for a slot, oldest first (``BrowserReplResource/queuedFetches``).
    private var queuedFetches: [PendingFetch] = []
    /// Driver calls waiting for a slot, oldest first (``BrowserReplResource/queuedDriverCalls``).
    private var queuedDriverCalls: [PendingDriverCall] = []
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
    /// The files this session's `secrets.load` protected
    /// (``BrowserReplSecretSources``), each counted once against its
    /// ``BrowserReplResource/secretSourceFiles`` quota. Used only on the
    /// session's thread, inside the file navigation lock.
    private var protectedSecretSources: Set<BrowserReplFileIdentity> = []

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
    /// The events among them hold ``BrowserReplResource/heldEvents``.
    private var heldCallbacks: [HeldCallback] = []
    private var releaseQueued = false
    private var resumeScheduled = false
    /// The timers the outermost run in progress set and has not cleared,
    /// or nil outside one.
    private var timersSetInRun: Set<Int>?
    /// The cell each pending timer belongs to: the cell running when it
    /// was set, or the cell of the timer whose callback set it (an
    /// interval re-arming itself). A cell's timeout cancels its timers
    /// (``cancelTimers(ofEval:)``), as it does its fetches and driver
    /// calls. JS thread only.
    private var timerOwners: [Int: Int] = [:]
    /// The cell of the timer whose callback runs now, or nil.
    private var firingTimerOwner: Int?
    /// When the JavaScript heap is measured next after a run that ends no
    /// cell (``measureScriptHeap(in:always:)``).
    private var nextHeapMeasure = ContinuousClock.now
    /// What the next cell reports about callbacks between cells.
    private var callbacksStopped = 0
    private var callbacksHeld = 0
    private var eventsDropped = 0
    /// The wait for the callback credit to recover; `close()` cancels it.
    private var callbackResume: Task<Void, Never>?

    private enum HeldCallback {
        case timer(Int)
        /// `reserved`: what the event holds of the queued-event budget.
        case event(name: String, payload: BrowserReplEgress, reserved: Int)
    }

    /// The most page events held back at once; past it the oldest go.
    static let maxHeldEvents = BrowserReplResourceLimits.standard[.heldEvents]

    /// The most page events queued for the session's thread or held back
    /// at once, and the most bytes they hold; an event past either is
    /// dropped where it arrives, before it is queued.
    static let maxQueuedEvents = BrowserReplResourceLimits.standard[.queuedEvents]
    static let maxQueuedEventBytes = BrowserReplResourceLimits.standard[.queuedEventBytes]

    /// The most bytes one page event's payload may have; a larger one
    /// arrives withheld (`{ targetId, withheld }`), without its content, so
    /// masking secrets in an event never reads more than this.
    static let maxEventPayloadBytes = BrowserReplResourceLimits.standard.each(.queuedEventBytes) ?? .max

    /// Page events dropped where they arrived since the last cell's
    /// notice; guarded by `eventLock`. The events queued or held, and their
    /// bytes, are in the ledger.
    private let eventLock = NSLock()
    private var eventsDroppedOnArrival = 0

    /// One evaluation's result. It is finished exactly once: by the JS
    /// thread when the cell settles, or from outside it by the timeout or
    /// `close()`, so a wedged JS thread can never strand the caller.
    ///
    /// Past ``BrowserReplResource/retainedOutputBytes`` of output, whatever
    /// reaches the native print (the runtime's own gate stops well before
    /// that), the rest goes to `<tmpdir>/output-<id>.txt` instead of memory,
    /// at most ``BrowserReplResource/spilledOutputBytes`` of it and only
    /// while the session's fs budget lasts; output past that is dropped.
    /// Both are reserved in the session's ledger and released when the
    /// cell ends (its lines then belong to the caller).
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
        /// Bytes of text kept in memory and spilled, as the summary counts them.
        private var retainedBytes = 0
        private var spilledBytes = 0
        /// What the kept lines hold (``BrowserReplOutputLine/retainedBytes``),
        /// reserved in the ledger.
        private var chargedBytes = 0
        /// Bytes written to the spill file.
        private var writtenBytes = 0
        private var spill: FileHandle?
        private var spilling = false
        /// What spill writes take from: the session's fs budget.
        private let spillBudget: BrowserReplWriteBudget
        private let ledger: BrowserReplResourceLedger

        /// - Parameter spillDirectory: The session's temporary directory,
        ///   held open (nil when it could not be made: output past the
        ///   ceiling is then dropped), with its path when it was made.
        init(
            id: Int,
            spillDirectory: (path: String, descriptor: BrowserReplDescriptor?),
            spillBudget: BrowserReplWriteBudget,
            ledger: BrowserReplResourceLedger,
            continuation: CheckedContinuation<BrowserReplEvalResult, Never>
        ) {
            self.id = id
            self.spillBudget = spillBudget
            self.ledger = ledger
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
                let charge = line.retainedBytes
                if !spilling, ledger.reserve(charge, of: .retainedOutputBytes) == nil {
                    chargedBytes += charge
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
                let refusal = ledger.reserve(size, of: .spilledOutputBytes)
                guard refusal == nil, (try? spillBudget.take(size, syscall: "write", display: spillName, callBytes: 0)) != nil else {
                    if refusal == nil { ledger.release(size, of: .spilledOutputBytes) }
                    try? file.close()
                    spill = nil
                    lines.append(BrowserReplOutputLine(
                        level: "info",
                        text: "# output past \(writtenBytes) bytes in \(spillPath ?? spillName) was dropped: a cell spills at most \(BrowserReplResourceLimits.describe(ledger.limits[.spilledOutputBytes], of: .spilledOutputBytes)), within the session's fs budget"
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
            // The lines go to the caller; the cell holds nothing any more.
            ledger.release(chargedBytes, of: .retainedOutputBytes)
            ledger.release(writtenBytes, of: .spilledOutputBytes)
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

    // The limits below are the session's ledger's
    // (``BrowserReplResourceLimits/standard``), by their older names.

    /// The most fetches one session has waiting for their response's
    /// headers at once; later fetches wait in order. A fetch whose headers
    /// arrived leaves its slot, so un-awaited fetches of bodies that never
    /// end (event streams) cannot hold every slot.
    static let maxConcurrentFetches = BrowserReplResourceLimits.standard[.requestPhaseFetches]

    /// The most fetches one session has open at once (waiting for headers,
    /// receiving a body, or holding a body the runtime has not taken yet),
    /// which bounds its connections. The bodies they hold at once are
    /// bounded by the fetcher's `BrowserReplFetchBudget`, and each fetch by
    /// `BrowserReplFetcher.resourceTimeout`.
    static let maxOpenFetches = BrowserReplResourceLimits.standard[.openFetches]

    /// The most fetches one session queues for a slot; past it a fetch fails at once.
    static let maxQueuedFetches = BrowserReplResourceLimits.standard[.queuedFetches]

    /// The most driver calls one session runs at once; later ones wait in
    /// order. The snapshot reads up to 256 frames at once (snapshot.js). A
    /// call keeps its slot until the runtime has its result, so results a
    /// busy JavaScript thread has not taken yet count too.
    static let maxConcurrentDriverCalls = BrowserReplResourceLimits.standard[.runningDriverCalls]

    /// The most UTF-8 bytes one driver call's result (or error) may have,
    /// 64 MiB; a larger one fails before the session masks or queues it.
    static let maxDriverResultBytes = BrowserReplResourceLimits.standard.each(.driverResultBytes) ?? .max

    /// The most bytes the driver results the runtime has not taken yet hold
    /// together, 512 MiB, measured as JavaScript will see them (masked); a
    /// result past it fails instead of waiting.
    static let maxWaitingDriverResultBytes = BrowserReplResourceLimits.standard[.driverResultBytes]

    /// The most driver calls one session queues; past it a call fails at once.
    static let maxQueuedDriverCalls = BrowserReplResourceLimits.standard[.queuedDriverCalls]

    /// The most UTF-8 bytes one driver call's parameters may have, 64 MiB
    /// (the fetch and `readFile` limit); a larger call fails where it is
    /// made, before anything holds it.
    static let maxDriverCallParamsBytes = BrowserReplResourceLimits.standard.each(.requestBytes) ?? .max

    /// A file chooser answer carries its files, Base64, up to
    /// ``BrowserReplUploadStaging/maximumBytes`` decoded (1 MiB more for
    /// names and the envelope).
    static let maxFileChooserAnswerBytes = BrowserReplUploadStaging.maximumBytes / 3 * 4 + (1 << 20)

    /// The most bytes of request data (driver call parameters, fetch
    /// requests) one session's waiting and running calls hold at once,
    /// 512 MiB; a call past it fails at once.
    static let maxHeldRequestBytes = BrowserReplResourceLimits.standard[.requestBytes]

    /// The most timers a session has scheduled, or fired with their callback
    /// not yet run, at once; `setTimer` returns false past it.
    public static let maxPendingTimers = BrowserReplResourceLimits.standard[.pendingTimers]

    /// The most output, in UTF-8 bytes, one evaluation keeps in memory; the
    /// rest goes to a file in the session's temporary directory.
    static let maxRetainedOutputBytes = BrowserReplResourceLimits.standard[.retainedOutputBytes]

    /// The most output, in UTF-8 bytes, one evaluation writes to its spill
    /// file; the rest is dropped.
    static let maxSpilledOutputBytes = BrowserReplResourceLimits.standard[.spilledOutputBytes]

    /// A tracked task, and the evaluation that was running when it started.
    private struct InFlightWork {
        let task: Task<Void, Never>
        let evalID: Int?
        let isFetch: Bool
        /// The request bytes it holds (``BrowserReplResource/requestBytes``).
        let heldBytes: Int
        /// The native input events it holds (``BrowserReplResource/inputEvents``).
        var inputEvents = 0
        /// The bytes its result holds until the runtime takes it
        /// (``BrowserReplResource/driverResultBytes``).
        var resultBytes = 0
    }

    /// A fetch the runtime asked for, waiting for a slot or running.
    private struct PendingFetch {
        let callID: Int
        let requestJSON: String
        let evalID: Int?
        /// What it holds of ``BrowserReplResource/requestBytes``.
        var heldBytes: Int { requestJSON.utf8.count }
    }

    /// A driver call the runtime asked for, its params already prepared.
    private struct PendingDriverCall {
        let callID: Int
        let method: String
        let paramsJSON: String
        let evalID: Int?
        /// What it holds of ``BrowserReplResource/requestBytes``.
        var heldBytes: Int { method.utf8.count + paramsJSON.utf8.count }
        /// What it holds of ``BrowserReplResource/inputEvents``.
        var inputEvents = 0
    }

    /// The native input events a driver call sends: an `input.drag` sends
    /// a move to its first point, the press, five steps along each segment
    /// of its path and the release (the driver's drag); other calls a
    /// bounded few, not counted.
    static func nativeInputEvents(method: String, paramsJSON: String) -> Int {
        guard method == BrowserReplDriverMethod.inputDrag.rawValue else { return 0 }
        let points = (JSONSerialization.browserReplObject(paramsJSON)["path"] as? [Any])?.count ?? 0
        return points < 2 ? 0 : 5 * (points - 1) + 3
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
            limits: BrowserReplResourceLimits.standard.with(.pendingTimers, maxPendingTimers),
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
    }

    /// - Parameters:
    ///   - limits: The session's resource limits (tests lower them).
    ///   - executionTimeLimitSupported: Whether this JavaScriptCore can stop
    ///     a running script (tests pass false); without it the session
    ///     refuses every cell.
    init(
        id: String,
        cwd: String?,
        bundle: BrowserReplRuntimeBundle,
        driver: any BrowserReplDriver,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock()),
        temporaryDirectory: String? = nil,
        homeDirectory: String? = nil,
        callbackTimeLimit: Duration = BrowserReplSession.defaultCallbackTimeLimit,
        limits: BrowserReplResourceLimits = .standard,
        executionTimeLimitSupported: Bool
    ) {
        let ledger = BrowserReplResourceLedger(limits: limits)
        self.ledger = ledger
        self.gate = BrowserReplEvalGate(ledger: ledger)
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
        let watchdog = BrowserReplWatchdog(callbackTimeLimit: callbackTimeLimit, supported: executionTimeLimitSupported)
        self.watchdog = watchdog
        // Masking runs on the JS thread inside host calls and result
        // delivery; it stops when the watchdog would stop the script.
        self.boundary = BrowserReplBoundary(
            typedSecrets: { driver.typedSecretRedaction() },
            isCancelled: { watchdog.shouldStopNativeWork }
        )
        self.sleeper = sleeper
        self.thread = BrowserReplJSThread(name: "com.cmux.browser-repl.\(id)")
        self.eventQueue = DispatchQueue(label: "com.cmux.browser-repl.events.\(id)", qos: .userInitiated)
        self.fetcher = BrowserReplFetcher(driver: driver, ledger: ledger)
        let writeBudget = BrowserReplWriteBudget(ledger: ledger)
        self.writeBudget = writeBudget
        self.fileSystem = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: resolvedCwd),
            temporaryDirectory: privateTemporaryDirectory,
            rootDescriptor: cwdDescriptor,
            temporaryDescriptor: privateTemporaryDescriptor,
            writeBudget: writeBudget,
            // A cell's timeout, close() and the callback limit stop the
            // running script; a long fs read, write or copy stops with it.
            isCancelled: { watchdog.shouldStopNativeWork }
        )
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock(), ledger: ledger) { [weak self] id in
            self?.fireTimer(id)
        }
        let boundary = self.boundary
        fetcher.setBlockReason { url in boundary.blockReason(url) }
        boundary.setFileRoots([fileSystem.sandbox.root] + (fileSystem.temporaryRoot.map { [$0] } ?? []))
        driver.setFileRoots([fileSystem.sandbox.root] + (fileSystem.temporaryRoot.map { [$0] } ?? []))
        driver.setSecretCheck { name, revision in boundary.secretIsCurrent(name: name, revision: revision) }
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

    /// The longest working directory, in UTF-8 bytes: `PATH_MAX`, the
    /// longest path the system opens. The path comes from the caller and is
    /// kept for the session's life, so a longer one is refused before it is.
    public static let maximumWorkingDirectoryBytes = Int(PATH_MAX)

    /// Why `cwd` is too long to be a working directory, or nil.
    public static func workingDirectoryLengthRefusal(_ cwd: String) -> String? {
        let bytes = cwd.utf8.count
        guard bytes > maximumWorkingDirectoryBytes else { return nil }
        return "refusing a REPL working directory of \(bytes) bytes: a path is at most \(maximumWorkingDirectoryBytes) bytes; cd to a shorter path and run the command again"
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

    /// Why the session ended by itself (its JavaScript heap passed its
    /// limit), or nil: ``BrowserReplSessionRegistry`` tells the next
    /// session of its name.
    public var endedReason: String? {
        stateLock.withLock { endReason }
    }

    /// Prints `line` (an error line) before the output of the next cell.
    func noteBeforeNextCell(_ line: String) {
        stateLock.withLock { notesBeforeNextCell.append(line) }
    }

    /// Evaluates one cell. Cells run one at a time in submission order.
    /// - Parameters:
    ///   - code: JavaScript source.
    ///   - cwd: New fs root, or `nil` to keep the current one.
    ///   - timeout: Evaluation timeout, at most ``maximumTimeout``; a
    ///     larger one is refused before the cell runs.
    ///   - maxOutput: Characters of output the cell prints before the rest
    ///     goes to a file (`0` for no limit), or `nil` for the runtime's
    ///     default (`repl-host.js`, `createOutputGate`).
    public func evaluate(
        code: String,
        cwd: String? = nil,
        timeout: Duration = BrowserReplSession.defaultTimeout,
        maxOutput: Int? = nil
    ) async -> BrowserReplEvalResult {
        guard timeout <= Self.maximumTimeout else {
            return BrowserReplEvalResult(
                lines: [],
                error: "Error: REPL session '\(id)': a cell's timeout is at most \(Self.milliseconds(Self.maximumTimeout)) ms (10 minutes); this one is \(Self.milliseconds(timeout)) ms",
                durationMilliseconds: 0
            )
        }
        if let refusal = await gate.acquire(sourceBytes: code.utf8.count) {
            return BrowserReplEvalResult(lines: [], error: "Error: REPL session '\(id)': \(refusal.message)", durationMilliseconds: 0)
        }
        // The runtime parses, rewrites and compiles the source before the
        // cell runs, holding several times its size, and the heap is only
        // measured when the cell ends: that is reserved first, so a cell
        // whose parse cannot fit beside what the session holds is refused
        // before it is parsed.
        let (product, overflow) = code.utf8.count.multipliedReportingOverflow(by: Self.parseBytesPerSourceByte)
        let parseBytes = overflow ? .max : product
        if let refusal = ledger.reserve(parseBytes, of: .runningCellParseBytes) {
            await gate.release()
            return BrowserReplEvalResult(lines: [], error: "Error: REPL session '\(id)': \(refusal.message)", durationMilliseconds: 0)
        }
        let result = await evaluateLocked(code: code, cwd: cwd, timeout: timeout, maxOutput: maxOutput)
        ledger.release(parseBytes, of: .runningCellParseBytes)
        await gate.release()
        return result
    }

    /// The memory reserved for each byte of a running cell's source while
    /// the runtime parses and compiles it: Acorn's syntax tree measured
    /// about 50 bytes per byte of dense code (V8, 8 MiB of `a=[1,2,…];`),
    /// beside the rewritten source and the compiled function.
    static let parseBytesPerSourceByte = 64

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
                ledger: ledger,
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
        if let reason = Self.workingDirectoryLengthRefusal(root) { return reason }
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
        close(reason: nil)
    }

    /// Like ``close()``, for a session that ended `ending`, which the
    /// driver gets (``BrowserReplDriver/detach(ending:)``).
    public func close(ending: BrowserReplSessionEnd) {
        close(reason: nil, ending: ending)
    }

    /// Like ``close()``; a running evaluation fails with `reason` (why the
    /// session ended) when given.
    private func close(reason: String?, ending: BrowserReplSessionEnd = .closed) {
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
        requestPhaseFetches.removeAll()
        queuedDriverCalls.removeAll()
        // What those held: their tasks no longer release it.
        ledger.releaseAll([.queuedFetches, .openFetches, .requestPhaseFetches, .queuedDriverCalls,
                           .runningDriverCalls, .requestBytes, .inputEvents, .driverResultBytes, .scriptHeapBytes])
        // Every script from now on, also one a block queued before this
        // runs, is terminated; a timeout's cleanup cannot clear that.
        watchdog.close()
        thread.perform { [self] in
            self.entryPoints = nil
            self.nativeHost = nil
            self.context = nil
            // Held events go with the session's thread.
            for case .event(_, _, let reserved) in self.heldCallbacks {
                self.releaseEvent(reserved)
                self.ledger.release(1, of: .heldEvents)
            }
            self.heldCallbacks.removeAll()
        }
        thread.stop()
        stateLock.unlock()
        for task in tasks { task.cancel() }
        scheduler.invalidate()
        driver.detach(ending: ending)
        fetcher.invalidate()
        running?.finish(error: reason ?? "Error: REPL session '\(id)' was closed")
        // Only an empty directory goes; files the session wrote stay, since
        // a one-shot run prints paths (spilled output, screenshots) that the
        // caller reads after the session has closed.
        if let ownedWorkingDirectory {
            rmdir(ownedWorkingDirectory)
        }
        rmdir(privateTemporaryDirectory)
    }

    /// `duration` in whole milliseconds.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// Finishes `state` and forgets it when it is still the current evaluation.
    private func finish(_ state: EvalState, error: String?) {
        stateLock.withLock {
            if currentEval === state {
                currentEval = nil
                watchdog.setCurrentEval(nil)
            }
        }
        state.finish(error: error.map { boundary.egress(.text($0)).text })
    }

    /// The evaluation timeout: the caller gets the timeout error now, from
    /// outside the JS thread. A script looping on the thread is terminated by
    /// the watchdog; then the runtime cancels the cell, so the cells after it
    /// run. Both are queued on the thread before the caller can submit
    /// another cell.
    private func timeOut(_ state: EvalState, after timeout: Duration) {
        let isCurrent = stateLock.withLock { currentEval === state && !closed }
        guard isCurrent else { return }
        let message = "Error: REPL evaluation timed out after \(Self.milliseconds(timeout))ms"
        watchdog.requestTermination()
        thread.perform { [self] in
            self.watchdog.clearTermination()
            self.cancelRunningCell(message, evalID: state.id, timers: self.cancelTimers(ofEval: state.id))
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
            ledger.release(fetches.reduce(0) { $0 + $1.heldBytes } + calls.reduce(0) { $0 + $1.heldBytes }, of: .requestBytes)
            ledger.release(fetches.count, of: .queuedFetches)
            ledger.release(calls.count, of: .queuedDriverCalls)
            ledger.release(calls.reduce(0) { $0 + $1.inputEvents }, of: .inputEvents)
            return (tasks, fetches.map(\.callID), calls.map(\.callID))
        }
        for task in tasks { task.cancel() }
        guard !droppedFetches.isEmpty || !droppedCalls.isEmpty else { return }
        thread.perform { [weak self] in
            for callID in droppedFetches { self?.refuseCall(callID, Self.cancelledFetchError) }
            for callID in droppedCalls { self?.refuseCall(callID, Self.cancelledDriverCallError) }
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
            var call = PendingDriverCall(callID: callID, method: method, paramsJSON: paramsJSON, evalID: currentEval?.id)
            call.inputEvents = Self.nativeInputEvents(method: method, paramsJSON: paramsJSON)
            if let refusal = admitRequestLocked(bytes: call.heldBytes) { return refusal.driverError(method) }
            // One call's events within its own limit and the session's,
            // before the driver sends any.
            if let refusal = ledger.reserve(call.inputEvents, of: .inputEvents) {
                ledger.release(call.heldBytes, of: .requestBytes)
                return refusal.driverError(method)
            }
            if queuedDriverCalls.isEmpty, ledger.reserve(1, of: .runningDriverCalls) == nil {
                startDriverCallLocked(call)
            } else if let refusal = ledger.reserve(1, of: .queuedDriverCalls) {
                ledger.release(call.heldBytes, of: .requestBytes)
                ledger.release(call.inputEvents, of: .inputEvents)
                return refusal.driverError(method)
            } else {
                queuedDriverCalls.append(call)
            }
            return nil
        }
    }

    /// Starts `call` as an in-flight task, its running slot already
    /// reserved. Call with `stateLock` held.
    private func startDriverCallLocked(_ call: PendingDriverCall) {
        nextInFlightID += 1
        let taskID = nextInFlightID
        let driver = self.driver
        // The task finishes itself; it waits for the lock held here, so the
        // entry exists before the removal runs. Its slot and its result's
        // bytes are held until the runtime has the result.
        let task = Task { [weak self] in
            let answer = await driver.call(method: call.method, paramsJSON: call.paramsJSON)
            guard let self else { return }
            let result = self.admitDriverResult(answer, of: call, taskID: taskID)
            // Behind the events the driver sent before it returned.
            self.eventQueue.async { [weak self] in
                guard let self else { return }
                let delivered = self.thread.perform { [weak self] in
                    self?.resolveCall(call.callID, result)
                    self?.driverCallFinished(taskID)
                }
                if !delivered { self.driverCallFinished(taskID) }
            }
        }
        inFlight[taskID] = InFlightWork(task: task, evalID: call.evalID, isFetch: false, heldBytes: call.heldBytes, inputEvents: call.inputEvents)
    }

    /// Frees the finished driver call's slot and starts queued ones.
    private func driverCallFinished(_ taskID: Int) {
        stateLock.withLock {
            // close() already dropped every entry and the queue.
            guard let work = inFlight.removeValue(forKey: taskID) else { return }
            ledger.release(work.heldBytes, of: .requestBytes)
            ledger.release(work.inputEvents, of: .inputEvents)
            ledger.release(work.resultBytes, of: .driverResultBytes)
            ledger.release(1, of: .runningDriverCalls)
            while !closed, !queuedDriverCalls.isEmpty, ledger.reserve(1, of: .runningDriverCalls) == nil {
                ledger.release(1, of: .queuedDriverCalls)
                startDriverCallLocked(queuedDriverCalls.removeFirst())
            }
        }
    }

    /// A finished driver call's result as the runtime will get it, its
    /// bytes reserved (``BrowserReplResource/driverResultBytes``) until
    /// ``driverCallFinished(_:)``. A result past the limit on one result,
    /// or one the waiting results leave no room for, becomes an error
    /// before it is masked, and so does one that masking grows past either.
    private func admitDriverResult(
        _ answer: Result<String, BrowserReplDriverError>,
        of call: PendingDriverCall,
        taskID: Int
    ) -> BrowserReplEgress {
        let method = call.method
        var answer = answer
        var reserved = Self.driverResultSize(answer)
        if let refusal = reserveDriverResult(bytes: reserved, replacing: 0, taskID: taskID) {
            answer = .failure(refusal.driverError(method))
            reserved = Self.driverResultSize(answer)
            reserveDriverResult(bytes: reserved, replacing: 0, taskID: taskID, force: true)
        }
        let result = boundary.egress(.driverResult(method: method, boundary.checkCaptureMasks(method: method, paramsJSON: call.paramsJSON, answer)))
        let size = result.size
        guard size != reserved, let refusal = reserveDriverResult(bytes: size, replacing: reserved, taskID: taskID) else { return result }
        let refused = boundary.egress(.driverResult(method: method, .failure(refusal.driverError("\(method) (with secrets masked)"))))
        reserveDriverResult(bytes: refused.size, replacing: reserved, taskID: taskID, force: true)
        return refused
    }

    /// Reserves `bytes` for task `taskID`'s result in place of the
    /// `replacing` it held, or says why it does not fit; `force` reserves a
    /// small error regardless. A task close() dropped reserves nothing.
    @discardableResult
    private func reserveDriverResult(
        bytes: Int,
        replacing: Int,
        taskID: Int,
        force: Bool = false
    ) -> BrowserReplResourceLimitError? {
        stateLock.withLock {
            guard inFlight[taskID] != nil else { return nil }
            let refusal = ledger.resize(.driverResultBytes, from: replacing, to: bytes, force: force)
            if refusal == nil { inFlight[taskID]?.resultBytes = bytes }
            return refusal
        }
    }

    /// What a driver result holds, in UTF-8 bytes.
    private static func driverResultSize(_ result: Result<String, BrowserReplDriverError>) -> Int {
        switch result {
        case .success(let json): json.utf8.count
        case .failure(let error): error.code.utf8.count + error.message.utf8.count + (error.errorName?.utf8.count ?? 0)
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
            if let refusal = admitRequestLocked(bytes: fetch.heldBytes) { return refusal.driverError("fetch") }
            if queuedFetches.isEmpty, reserveFetchSlotLocked() {
                startFetchLocked(fetch)
            } else if let refusal = ledger.reserve(1, of: .queuedFetches) {
                ledger.release(fetch.heldBytes, of: .requestBytes)
                return refusal.driverError("fetch")
            } else {
                queuedFetches.append(fetch)
            }
            return nil
        }
    }

    /// Reserves `bytes` of ``BrowserReplResource/requestBytes`` for a call
    /// about to wait or run, or says why it is refused. One call's own
    /// limit was checked where it was made. Call with `stateLock` held.
    private func admitRequestLocked(bytes: Int) -> BrowserReplResourceLimitError? {
        ledger.reserve(bytes, of: .requestBytes, each: .max)
    }

    /// Reserves a fetch's slots (``BrowserReplResource/openFetches`` and
    /// ``BrowserReplResource/requestPhaseFetches``) when both are free.
    /// Call with `stateLock` held.
    private func reserveFetchSlotLocked() -> Bool {
        guard ledger.reserve(1, of: .openFetches) == nil else { return false }
        guard ledger.reserve(1, of: .requestPhaseFetches) == nil else {
            ledger.release(1, of: .openFetches)
            return false
        }
        return true
    }

    /// Starts `fetch` as an in-flight task, its slots already reserved.
    /// Call with `stateLock` held.
    private func startFetchLocked(_ fetch: PendingFetch) {
        nextInFlightID += 1
        let taskID = nextInFlightID
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
            let result = boundary.egress(.fetch(raw))
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
            ledger.release(1, of: .requestPhaseFetches)
            startQueuedFetchesLocked()
        }
    }

    /// Frees the finished fetch's slot and starts queued ones.
    private func fetchFinished(_ taskID: Int) {
        stateLock.withLock {
            // close() already dropped every entry and the queue.
            guard let work = inFlight.removeValue(forKey: taskID) else { return }
            ledger.release(work.heldBytes, of: .requestBytes)
            ledger.release(1, of: .openFetches)
            if requestPhaseFetches.remove(taskID) != nil { ledger.release(1, of: .requestPhaseFetches) }
            startQueuedFetchesLocked()
        }
    }

    /// Starts the oldest queued fetches while slots are free. Call with `stateLock` held.
    private func startQueuedFetchesLocked() {
        while !closed, !queuedFetches.isEmpty, reserveFetchSlotLocked() {
            ledger.release(1, of: .queuedFetches)
            startFetchLocked(queuedFetches.removeFirst())
        }
    }

    /// Asks the runtime to drop cell `evalID` if it is still running
    /// (`__cmuxReplCancel`); a cell that already ended is left alone. The
    /// runtime forgets the callbacks of `timers` either way, so a fire
    /// already queued for one runs nothing.
    private func cancelRunningCell(_ message: String, evalID: Int, timers: [Int] = []) {
        guard let context, !isClosedNow, let cancel = entryPoints?.cancel else { return }
        enter(context) { _ = cancel.call(withArguments: [message, evalID, timers]) }
    }

    /// Cancels the timers cell `evalID` owns (``timerOwners``), the held
    /// ones too, and returns their ids. JS thread only.
    private func cancelTimers(ofEval evalID: Int) -> [Int] {
        let ids = timerOwners.compactMap { $0.value == evalID ? $0.key : nil }
        guard !ids.isEmpty else { return [] }
        let cancelled = Set(ids)
        for id in ids {
            timerOwners.removeValue(forKey: id)
            scheduler.cancel(id: id)
        }
        heldCallbacks.removeAll { held in
            if case .timer(let id) = held { return cancelled.contains(id) }
            return false
        }
        return ids
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
        // A fired timer's callback works for the timer's cell.
        let previousOwner = firingTimerOwner
        if let firedTimer { firingTimerOwner = timerOwners.removeValue(forKey: firedTimer) }
        defer { firingTimerOwner = previousOwner }
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
        if !isClosedNow, stateLock.withLock({ endReason == nil }),
           let reason = measureScriptHeap(in: context, always: false) {
            end(because: reason)
        }
    }

    // MARK: - JavaScript heap

    /// The least time between two heap measures after runs that end no
    /// cell; a measure that took longer waits 20 times as long, so
    /// measuring uses at most 5% of the thread's time.
    static let heapMeasureInterval: Duration = .milliseconds(10)

    /// Measures the session's JavaScript heap into the ledger
    /// (``BrowserReplResource/scriptHeapBytes``, which counts toward the
    /// session's memory). JavaScriptCore has no heap limit of its own
    /// (``BrowserReplScriptHeap``), so this is the bound: past a limit the
    /// heap's garbage is collected and it is measured again, and when it
    /// is still past, the session ends. `always` measures now (a cell is
    /// ending); otherwise only once ``heapMeasureInterval`` (or 20 times
    /// the last measure's cost) has passed. JavaScript a cell or callback
    /// makes while it runs is measured once it returns to the session and,
    /// while it goes on, at the watchdog's checks (``BrowserReplWatchdog/checkInterval``).
    /// - Returns: Why the session ends, or nil.
    private func measureScriptHeap(in context: JSContext, always: Bool) -> String? {
        let start = ContinuousClock.now
        guard always || start >= nextHeapMeasure else { return nil }
        let heap = BrowserReplScriptHeap(context: context)
        guard var bytes = heap.size() else { return nil }
        let held = ledger.held(.scriptHeapBytes)
        var refusal = ledger.resize(.scriptHeapBytes, from: held, to: bytes)
        if refusal != nil {
            heap.collect()
            bytes = heap.size() ?? bytes
            refusal = ledger.resize(.scriptHeapBytes, from: held, to: bytes)
        }
        let finish = ContinuousClock.now
        nextHeapMeasure = finish + max(Self.heapMeasureInterval, (finish - start) * 20)
        guard let refusal else { return nil }
        // The session ends with what it held; close() releases it.
        ledger.resize(.scriptHeapBytes, from: held, to: bytes, force: true)
        let describe = { BrowserReplResourceLimits.describe($0, of: BrowserReplResource.scriptHeapBytes) }
        let resource = BrowserReplResource.scriptHeapBytes
        return "Error: REPL session '\(id)' ended: REPL session limit: \(resource.title) at most \(describe(refusal.limit)) "
            + "(it held \(describe(bytes)) after a full garbage collection); \(resource.remedy). The next command starts a new session"
    }

    /// The watchdog's check of a run that goes on: measures the heap (at
    /// most as often as between runs) and, past its limit, ends the
    /// session, which terminates the run. On the session's thread.
    /// - Returns: Whether the session ended.
    private func heapIsPastLimitDuringRun() -> Bool {
        guard let context, !isClosedNow, stateLock.withLock({ endReason == nil }) else { return false }
        guard let reason = measureScriptHeap(in: context, always: false) else { return false }
        end(because: reason)
        return true
    }

    /// Ends the session for `reason` (its JavaScript heap is past its
    /// limit): no more of its JavaScript runs, and the cell running, or the
    /// next session of its name, says why. Called on the session's thread,
    /// which `close()` stops, so the close runs off it.
    private func end(because reason: String) {
        stateLock.withLock { endReason = reason }
        watchdog.close()
        DispatchQueue.global(qos: .userInitiated).async { [self] in close(reason: reason) }
    }

    /// Finishes `state` on the session's thread, as its cell ends: the
    /// heap is measured first, and a heap past its limit ends the session
    /// and the cell with it.
    private func finishOnThread(_ state: EvalState, error: String?) {
        // The heap ended the session while the cell ran: the cell says why,
        // not how its terminated script ended.
        if let reason = stateLock.withLock({ endReason }) {
            finish(state, error: reason)
            return
        }
        if let context, !isClosedNow, let reason = measureScriptHeap(in: context, always: true) {
            end(because: reason)
            return
        }
        finish(state, error: error)
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
            if ledger.reserve(1, of: .heldEvents) != nil,
               let oldest = heldCallbacks.firstIndex(where: { if case .event = $0 { true } else { false } }) {
                // The oldest held event goes and its place is this one's.
                if case .event(_, _, let reserved) = heldCallbacks.remove(at: oldest) { releaseEvent(reserved) }
                eventsDropped += 1
            }
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
            for case .event(_, _, let reserved) in heldCallbacks {
                releaseEvent(reserved)
                ledger.release(1, of: .heldEvents)
            }
            heldCallbacks.removeAll()
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
            ledger.release(1, of: .heldEvents)
            releaseEvent(reserved)
            if let handler = entryPoints.onEvent {
                enter(context) { _ = handler.call(withArguments: [name, payload.text]) }
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
        var lines: [String] = stateLock.withLock {
            defer { notesBeforeNextCell.removeAll() }
            return notesBeforeNextCell
        }
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
            lines.append("cmux browser repl: \(eventsDropped) page events were dropped because \(ledger.limits[.heldEvents]) were already waiting")
        }
        if droppedOnArrival > 0 {
            lines.append("cmux browser repl: \(droppedOnArrival) page events were dropped because \(ledger.limits[.queuedEvents]) events or \(BrowserReplResourceLimits.describe(ledger.limits[.queuedEventBytes], of: .queuedEventBytes)) of them were already waiting for the session's thread")
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
            finishOnThread(state, error: state.isFinished ? nil : formatError(exception, in: context))
            return
        }
        guard let promise, promise.isObject, let then = promise.objectForKeyedSubscript("then"), !then.isUndefined else {
            finishOnThread(state, error: nil)
            return
        }
        let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] _ in
            self?.finishOnThread(state, error: nil)
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] reason in
            guard let self, !state.isFinished, let context = self.context else { return }
            let text = reason.map { self.formatError($0, in: context) } ?? "Error: undefined"
            self.finishOnThread(state, error: text)
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
        // A run that goes on is measured too: JavaScriptCore cannot refuse
        // an allocation, so a cell that keeps allocating would otherwise
        // hold the app's memory until it returns or times out.
        watchdog.setRunCheck { [weak self] in self?.heapIsPastLimitDuringRun() ?? false }
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
                level: BrowserReplOutputLine.level(of: level),
                text: self.boundary.egress(.text(text?.toString() ?? "")).text
            ))
        }
        let setTimer: @convention(block) (JSValue?, JSValue?, JSValue?) -> Bool = { [weak self] id, delay, repeating in
            guard let self, let id = id?.toInt32() else { return false }
            let duration = Duration.milliseconds(BrowserReplSession.timerDelayMilliseconds(delay?.toDouble()))
            guard self.scheduler.schedule(id: Int(id), after: duration, repeating: repeating?.toBool() ?? false) else { return false }
            self.timersSetInRun?.insert(Int(id))
            if let owner = self.firingTimerOwner ?? self.runningEvalID {
                self.timerOwners[Int(id)] = owner
            } else {
                self.timerOwners.removeValue(forKey: Int(id))
            }
            return true
        }
        let clearTimer: @convention(block) (JSValue?) -> Void = { [weak self] id in
            guard let self, let id = id?.toInt32() else { return }
            self.scheduler.cancel(id: Int(id))
            // So the run's list holds at most the pending timers.
            self.timersSetInRun?.remove(Int(id))
            self.timerOwners.removeValue(forKey: Int(id))
        }
        let driverCall: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] callID, method, params in
            guard let self, let callID = callID?.toInt32() else { return }
            let methodName = method?.toString() ?? ""
            let raw = params.flatMap { $0.isString ? $0.toString() : nil } ?? "{}"
            // An oversized call is refused before it is parsed or waits.
            let limit = methodName == "filechooser.respond" ? Self.maxFileChooserAnswerBytes : (self.ledger.limits.each(.requestBytes) ?? .max)
            guard raw.utf8.count <= limit else {
                let refusal = BrowserReplResourceLimitError(resource: .requestBytes, limit: limit, isPerItem: true, held: self.ledger.held(.requestBytes), requested: raw.utf8.count)
                self.refuseCall(Int(callID), refusal.driverError(methodName), method: methodName)
                return
            }
            // So is one whose JSON no call may hold, which the parse below
            // and the driver's could not stop.
            if let reason = JSONSerialization.browserReplCallStructureRefusal(raw) {
                self.refuseCall(Int(callID), BrowserReplDriverError(code: "invalid", message: "\(methodName): \(reason)"), method: methodName)
                return
            }
            let boundary = self.boundary
            let paramsJSON: String
            switch boundary.prepare(method: methodName, paramsJSON: raw) {
            case .success(let prepared): paramsJSON = prepared
            case .failure(let error):
                self.refuseCall(Int(callID), error, method: methodName)
                return
            }
            // A file chooser answer's files are staged on disk until the
            // session ends, so they count against its write budget.
            if methodName == "filechooser.respond" {
                do {
                    try self.writeBudget.takeFileChooserAnswer(JSONSerialization.browserReplObject(paramsJSON))
                } catch let error as BrowserReplFileSystemError {
                    self.refuseCall(Int(callID), BrowserReplDriverError(code: "invalid", message: "filechooser: \(error.message)"), method: methodName)
                    return
                } catch {
                    self.refuseCall(Int(callID), BrowserReplDriverError(code: "invalid", message: "filechooser: \(error)"), method: methodName)
                    return
                }
            }
            if let refusal = self.startOrQueueDriverCall(callID: Int(callID), method: methodName, paramsJSON: paramsJSON) {
                self.refuseCall(Int(callID), refusal, method: methodName)
            }
        }
        let fetch: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] callID, request in
            guard let self, let callID = callID?.toInt32() else { return }
            let requestJSON = request?.toString() ?? "{}"
            // An oversized body is refused before it waits in the queue.
            if let refusal = BrowserReplFetcher.oversizedRequest(requestJSON) {
                self.refuseCall(Int(callID), refusal, method: "fetch")
                return
            }
            if let refusal = self.startOrQueueFetch(callID: Int(callID), requestJSON: requestJSON) {
                self.refuseCall(Int(callID), refusal, method: "fetch")
            }
        }
        let fs = hostFunction("fs", isFileSystem: true) { [weak self] op, arguments in
            guard let self else { return nil }
            var args = JSONSerialization.browserReplObject(arguments)
            func failure(_ code: String, _ message: String) -> BrowserReplEgress {
                self.boundary.egress(.fs(op: op, .failure(BrowserReplFileSystemError(code: code, message: message))))
            }
            // Text the runtime writes (output spill files, traces, any file)
            // is masked like output, by the gate's scan.
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
                if let mask = self.boundary.fileStoreRedaction(syscall: "write") {
                    let isCancelled = self.boundary.isCancelled
                    let cancelled = BrowserReplFileSystem.cancelledError(syscall: "write", display: "")
                    let decoded: Data?
                    do {
                        decoded = try Data(browserReplBase64: base64, isCancelled: isCancelled)
                    } catch {
                        return failure(cancelled.code, cancelled.message)
                    }
                    if let data = decoded {
                        do {
                            let masked = try mask(data)
                            if masked != data { args["base64"] = try masked.browserReplBase64EncodedString(isCancelled: isCancelled) }
                        } catch let error as BrowserReplFileSystemError where error.code == "ECANCELED" {
                            return failure(error.code, error.message)
                        } catch is CancellationError {
                            return failure(cancelled.code, cancelled.message)
                        } catch {
                            return failure("EINVAL", "writeFile: \(BrowserReplSecretStore.limitMessage(data.count))")
                        }
                    }
                }
            }
            // So is a copy: its source may be a file the session never
            // wrote (a page's download, a secrets file).
            let copyContents = op == "copyFile" ? self.boundary.fileStoreRedaction(syscall: "copyfile") : nil
            return self.boundary.egress(.fs(op: op, self.fileSystem.perform(op, arguments: args, copyContents: copyContents)))
        }
        let secrets = hostFunction("secrets") { [weak self] op, arguments in
            guard let self else { return nil }
            var args = JSONSerialization.browserReplObject(arguments)
            // secrets.load(path) reads the file here, so its values never
            // reach JavaScript.
            if op == "load", let path = args["path"] as? String {
                // The file, under any name, never loads in a tab
                // (BrowserReplSecretSources): a tab would show its values
                // as pixels no mask covers. Protected in the same hold of
                // the file navigation lock as the open, before its values
                // are known to be readable.
                // A file new to the session takes one of its quota first
                // (a lifetime count, so a refusal of the app-wide set still
                // takes it), and is never protected past the quota.
                let opened: (BrowserReplFileIdentity) throws -> Void = { identity in
                    guard !self.protectedSecretSources.contains(identity) else { return }
                    if let refusal = self.ledger.reserve(1, of: .secretSourceFiles) {
                        throw BrowserReplFileSystemError(code: "limit", message: refusal.message)
                    }
                    try BrowserReplSecretSources.shared.protect(identity)
                    self.protectedSecretSources.insert(identity)
                }
                switch self.fileSystem.perform("readFile", arguments: ["path": path], copyContents: nil, opened: opened) {
                case .failure(let error):
                    return self.boundary.egress(.host(.failure(BrowserReplDriverError(code: error.code, message: "secrets.load: \(error.message)"))))
                case .success(let base64):
                    // Parsing cannot stop midway on this thread, so a file
                    // past the limit is refused before it is decoded, and
                    // the deadline is checked around the parse.
                    let isCancelled = self.boundary.isCancelled
                    let text = base64 as? String ?? ""
                    let size = text.utf8.count / 4 * 3
                    guard size <= BrowserReplSecretStore.maximumLoadFileBytes + 2 else {
                        let limit = BrowserReplSecretStore.maximumLoadFileBytes >> 20
                        return self.boundary.egress(.host(.failure(BrowserReplDriverError(code: "invalid", message: "secrets.load: \(path) is about \(size) bytes, past the \(limit) MiB a secrets file may hold"))))
                    }
                    let data: Data?
                    do {
                        data = try Data(browserReplBase64: text, isCancelled: isCancelled)
                    } catch {
                        return self.boundary.egress(.host(.failure(BrowserReplBoundary.cancelled("secrets.load"))))
                    }
                    if let data, let reason = BrowserReplSecretStore.loadSourceRefusal(data) {
                        return self.boundary.egress(.host(.failure(BrowserReplDriverError(code: "invalid", message: "secrets.load: \(path) \(reason)"))))
                    }
                    guard let data, !isCancelled(), let object = try? JSONSerialization.jsonObject(with: data) else {
                        if isCancelled() { return self.boundary.egress(.host(.failure(BrowserReplBoundary.cancelled("secrets.load")))) }
                        return self.boundary.egress(.host(.failure(BrowserReplDriverError(code: "invalid", message: "secrets.load: \(path) is not JSON"))))
                    }
                    args["object"] = object
                }
            }
            return self.boundary.egress(.host(self.boundary.secretsOperation(op, args)))
        }
        let policy = hostFunction("policy") { [weak self] op, arguments in
            guard let self else { return nil }
            let (result, updated) = self.boundary.policyOperation(op, JSONSerialization.browserReplObject(arguments))
            if let updated { self.driver.setDomainPolicy(updated) }
            return self.boundary.egress(.host(result))
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

    /// A synchronous host function (`fs`, `secrets`, `policy`): its answer
    /// is whatever the egress gate gave `body`; `nil` (the session is
    /// gone) answers that the session was closed.
    ///
    /// The call's operation and arguments are reserved in the session's
    /// ledger (``BrowserReplResource/hostCallBytes``, within its memory)
    /// before they are copied out of JavaScript, parsed or decoded, and
    /// released when it returns; one past its limit
    /// (``hostCallLimit(isFileSystem:)``) or the session's memory is
    /// refused with nothing parsed, and so are arguments whose JSON holds
    /// more elements or nests deeper than one call may
    /// (``JSONSerialization/browserReplCallStructureRefusal(_:)``).
    private func hostFunction(
        _ name: String,
        isFileSystem: Bool = false,
        _ body: @escaping (_ operation: String, _ arguments: String) -> BrowserReplEgress?
    ) -> @convention(block) (JSValue?, JSValue?) -> String {
        { [weak self] operation, arguments in
            guard let self else { return #"{"error":{"code":"closed","message":"closed"}}"# }
            let limit = self.hostCallLimit(isFileSystem: isFileSystem)
            func refuse(_ refusal: BrowserReplResourceLimitError) -> String {
                if isFileSystem {
                    let code = refusal.isPerItem ? "E2BIG" : "ENOMEM"
                    return self.boundary.egress(.fs(op: "", .failure(BrowserReplFileSystemError(code: code, message: "\(code): \(refusal.message)")))).text
                }
                return self.boundary.egress(.host(.failure(refusal.driverError(name)))).text
            }
            // A JavaScript string's length in UTF-16 code units is at most
            // its UTF-8 size, so a string past the limit by its length is
            // refused before it is copied.
            let units = [operation, arguments].reduce(0) { total, value in
                guard let value, value.isString, let length = value.forProperty("length")?.toDouble(), length.isFinite else { return total }
                return total + Int(min(length, Double(Int.max / 4)))
            }
            if units > limit {
                return refuse(BrowserReplResourceLimitError(resource: .hostCallBytes, limit: limit, isPerItem: true, held: self.ledger.held(.hostCallBytes), requested: units))
            }
            let op = operation?.toString() ?? ""
            let raw = arguments.flatMap { $0.isString ? $0.toString() : nil } ?? "{}"
            let bytes = op.utf8.count + raw.utf8.count
            if let refusal = self.ledger.reserve(bytes, of: .hostCallBytes, each: limit) { return refuse(refusal) }
            defer { self.ledger.release(bytes, of: .hostCallBytes) }
            // Arguments whose JSON no call may hold are refused before the
            // parse, which no timeout interrupts.
            if let reason = JSONSerialization.browserReplCallStructureRefusal(raw) {
                if isFileSystem {
                    return self.boundary.egress(.fs(op: "", .failure(BrowserReplFileSystemError(code: "E2BIG", message: "E2BIG: \(reason)")))).text
                }
                return self.boundary.egress(.host(.failure(BrowserReplDriverError(code: "invalid", message: "\(name): \(reason)")))).text
            }
            return body(op, raw)?.text ?? #"{"error":{"code":"closed","message":"closed"}}"#
        }
    }

    /// The most one synchronous host call's operation and arguments may
    /// hold: an fs call carries one write's bytes in Base64 (the fs write
    /// limit, 256 MiB, plus 1 MiB for the rest), any other call the
    /// ledger's own per-call limit.
    func hostCallLimit(isFileSystem: Bool) -> Int {
        let each = ledger.limits.each(.hostCallBytes) ?? .max
        guard isFileSystem, let write = ledger.limits.each(.fileBytesWritten) else { return each }
        return max(each, (write / 3 + 1) * 4 + (1 << 20))
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

    /// Refuses call `callID` with `error`, through the egress gate.
    private func refuseCall(_ callID: Int, _ error: BrowserReplDriverError, method: String = "") {
        resolveCall(callID, boundary.egress(.driverResult(method: method, .failure(error))))
    }

    /// Hands call `callID`'s answer to JavaScript: only what the egress gate
    /// gave.
    private func resolveCall(_ callID: Int, _ answer: BrowserReplEgress) {
        guard let context, !isClosedNow, let resolve = entryPoints?.onResult else { return }
        enter(context) {
            switch answer.result {
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
        let admitted = admitEvent(bytes: reserved)
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
                self.enter(context) { _ = handler.call(withArguments: [name, payload.text]) }
            }
            if !queued { self.releaseEvent(charged) }
        }
    }

    /// Reserves one queued event of `bytes` (raw, so one past the limit
    /// on one event still fits: it arrives withheld), or counts it dropped.
    private func admitEvent(bytes: Int) -> Bool {
        eventLock.withLock {
            guard ledger.reserve(1, of: .queuedEvents) == nil else {
                eventsDroppedOnArrival += 1
                return false
            }
            guard ledger.reserve(bytes, of: .queuedEventBytes, each: .max) == nil else {
                ledger.release(1, of: .queuedEvents)
                eventsDroppedOnArrival += 1
                return false
            }
            return true
        }
    }

    /// The payload of an admitted event as JavaScript will see it, and the
    /// bytes it now holds of ``BrowserReplResource/queuedEventBytes``:
    /// masking can make it longer than the raw bytes it was admitted with
    /// (`reserved`), and one that would pass the budget masked arrives
    /// withheld instead.
    private func chargeMaskedEvent(name: String, raw: String, reserved: Int) -> (payload: BrowserReplEgress, reserved: Int) {
        let masked = boundary.egress(.event(name: name, payloadJSON: raw, maxBytes: ledger.limits.each(.queuedEventBytes) ?? .max))
        let size = name.utf8.count + masked.size
        // The limit on one event applied to the raw payload, before masking.
        if ledger.resize(.queuedEventBytes, from: reserved, to: size, each: .max) == nil {
            return (masked, size)
        }
        let reason = "this \(name) event is \(masked.size) bytes with secrets masked, and the page events waiting for the session's thread already hold close to \(BrowserReplResourceLimits.describe(ledger.limits[.queuedEventBytes], of: .queuedEventBytes)), so its content was withheld"
        let withheld = boundary.egress(.withheldEvent(payloadJSON: raw, reason: reason))
        let withheldSize = name.utf8.count + withheld.size
        ledger.resize(.queuedEventBytes, from: reserved, to: withheldSize, force: true)
        return (withheld, withheldSize)
    }

    /// An event left the queue (delivered or dropped): its budget is free.
    private func releaseEvent(_ reserved: Int) {
        ledger.release(1, of: .queuedEvents)
        ledger.release(reserved, of: .queuedEventBytes)
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

/// Serializes evaluations of one session without blocking a thread, and
/// bounds the cells waiting and the source they hold in the session's
/// ledger (``BrowserReplResource/waitingCells``,
/// ``BrowserReplResource/waitingCellSourceBytes``).
actor BrowserReplEvalGate {
    private let ledger: BrowserReplResourceLedger
    private var busy = false
    private var waiters: [(continuation: CheckedContinuation<Void, Never>, sourceBytes: Int)] = []

    init(ledger: BrowserReplResourceLedger) {
        self.ledger = ledger
    }

    /// Waits for the running cell, or returns why the cell may not wait.
    func acquire(sourceBytes: Int) async -> BrowserReplResourceLimitError? {
        if !busy {
            busy = true
            return nil
        }
        if let refusal = ledger.reserve(1, of: .waitingCells) { return refusal }
        if let refusal = ledger.reserve(sourceBytes, of: .waitingCellSourceBytes) {
            ledger.release(1, of: .waitingCells)
            return refusal
        }
        await withCheckedContinuation { waiters.append(($0, sourceBytes)) }
        return nil
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            ledger.release(1, of: .waitingCells)
            ledger.release(next.sourceBytes, of: .waitingCellSourceBytes)
            next.continuation.resume()
        }
    }
}
