import CmuxNextCompat
public import CmuxNextWakeups

/// The app process's crash report and Rust diagnostics forwarders (cx-urd.58, cx-urd.59),
/// started as one unit: the helper crash reports (``SystemCrashForwarder``), the panic and hang logs of the cmux-tui
/// owner and the other shipped Rust processes and, when this app runs one, the acpmux daemon's
/// (``RustDiagnosticsForwarder``).
///
/// ``start()`` starts each on its own queue now. ``run()`` does the same work on the calling thread, which
/// may block on files, and ``post(on:)`` posts it as one afterStartup best-effort files-lane task, so it waits
/// for startup completion and the best-effort fence (feature `crashForwardersAfterStartup`), as
/// Chrome posts non-critical startup work with `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc) to a BEST_EFFORT ThreadPool runner. Either way the first pass
/// sends what the last run left: each forwarder keeps its watermark or offset across runs, so a report written
/// before the first pass of this launch is sent by it.
///
/// With `systemWaitsForRelease` the helper crash forwarder starts only once both have happened: the start (``start()``,
/// ``run()`` or ``post(on:)``) and ``releaseSystem()`` (the app calls it at the hang-reports controller's first
/// decision, so no pass sends a Rust crash's black box before consent is decided). Released
/// before the start, it runs with the others; released after, it starts then on its own queue.
///
/// ```swift
/// let forwarders = CrashForwarders(system: system, ownerPanics: owner) { acpmuxForwarder() }
/// forwarders.post(on: startup)   // or forwarders.start() with no launch to wait for
/// ```
public final class CrashForwarders: Sendable {
    /// The afterStartup post's name in the startup log.
    public static let taskName: StaticString = "CrashReporting.forwarders"
    /// The helper crash report forwarder.
    public let system: SystemCrashForwarder
    /// The cmux-tui owner's diagnostics log forwarder (in the app, every shipped Rust process's but acpmux's).
    public let ownerPanics: OwnerPanicForwarder
    private let makeAcpmuxPanics: @Sendable () -> OwnerPanicForwarder?
    /// The acpmux forwarder once made, kept for the process's life: its folder watch lives as long as it does; and the
    /// hang-report sink once attached (``setHangEntries(_:)``), so the forwarder made later gets it too. One lock for
    /// both, so each forwarder gets the sink exactly once whichever comes first.
    private let acpmux = Mutex<(forwarder: OwnerPanicForwarder?, hangEntries: OwnerPanicForwarder.HangEntries?)>((nil, nil))
    /// Whether the forwarders started, whether the helper crash forwarder was released and whether it started: it
    /// starts once, at whichever of the two comes last.
    private let systemGate: Mutex<(started: Bool, released: Bool, systemStarted: Bool)>

    /// - Parameters:
    ///   - system: The helper crash report forwarder.
    ///   - ownerPanics: The owner's diagnostics log forwarder.
    ///   - systemWaitsForRelease: The helper crash forwarder waits for ``releaseSystem()`` too; false starts it with
    ///     the others.
    ///   - acpmuxPanics: Makes the acpmux daemon's diagnostics log forwarder, or nil with no acpmux; called once, by
    ///     ``start()`` or ``run()``, because finding acpmux reads the file system.
    public init(system: SystemCrashForwarder, ownerPanics: OwnerPanicForwarder, systemWaitsForRelease: Bool = false,
                acpmuxPanics: @escaping @Sendable () -> OwnerPanicForwarder?) {
        self.system = system
        self.ownerPanics = ownerPanics
        makeAcpmuxPanics = acpmuxPanics
        systemGate = Mutex((started: false, released: !systemWaitsForRelease, systemStarted: false))
    }

    /// Lets the helper crash forwarder start: now on its own queue if the forwarders started, else with them. Only the
    /// first call counts.
    public func releaseSystem() {
        let startNow = systemGate.withLock { gate -> Bool in
            gate.released = true
            return gate.started && Self.claimSystem(&gate)
        }
        if startNow { system.start() }
    }

    /// The acpmux daemon's panic log forwarder, once ``start()`` or ``run()`` made it.
    public var acpmuxPanics: OwnerPanicForwarder? { acpmux.withLock { $0.forwarder } }

    /// Attaches where each Rust hang line sent goes besides Sentry (the hang-report collector), once at launch: to the
    /// owner's forwarder now and to acpmux's now or when it is made (``OwnerPanicForwarder/setHangEntries(_:)``).
    public func setHangEntries(_ entries: @escaping OwnerPanicForwarder.HangEntries) {
        let made = acpmux.withLock { state -> OwnerPanicForwarder? in
            state.hangEntries = entries
            return state.forwarder
        }
        ownerPanics.setHangEntries(entries)
        made?.setHangEntries(entries)
    }

    /// Starts every forwarder on its own queue. Call it, or ``run()``, once.
    public func start() {
        if markStarted() { system.start() }
        ownerPanics.start()
        makeAcpmux()?.start()
    }

    /// Runs ``run()`` in one afterStartup post of `startup` on a best-effort files lane: never before startup
    /// completes, never after a quit that began before. Call it, ``start()`` or ``run()``, once.
    public func post(on startup: StartupScheduler) {
        startup.post(.afterStartup, Self.taskName, on: .lane(.files, .bestEffort)) { [self] in run() }
    }

    /// Sends what each forwarder's log holds since its last run and starts their watches, on the calling
    /// thread (a files lane). Call it, or ``start()``, once.
    public func run() {
        if markStarted() { system.forwardAndWatch() }
        ownerPanics.forwardAndWatch()
        makeAcpmux()?.forwardAndWatch()
    }

    /// Marks the forwarders started; returns whether the helper crash forwarder starts now.
    private func markStarted() -> Bool {
        systemGate.withLock { gate in
            gate.started = true
            return gate.released && Self.claimSystem(&gate)
        }
    }

    private static func claimSystem(_ gate: inout (started: Bool, released: Bool, systemStarted: Bool)) -> Bool {
        guard !gate.systemStarted else { return false }
        gate.systemStarted = true
        return true
    }

    private func makeAcpmux() -> OwnerPanicForwarder? {
        guard let forwarder = makeAcpmuxPanics() else { return nil }
        let entries = acpmux.withLock { state -> OwnerPanicForwarder.HangEntries? in
            state.forwarder = forwarder
            return state.hangEntries
        }
        if let entries { forwarder.setHangEntries(entries) }
        return forwarder
    }
}
