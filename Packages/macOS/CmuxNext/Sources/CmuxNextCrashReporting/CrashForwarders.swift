import CmuxNextCompat
public import CmuxNextWakeups

/// The app process's crash report and panic log forwarders (cx-urd.58, cx-urd.59), started as one unit:
/// the helper crash reports (``SystemCrashForwarder``), the cmux-tui owner's panic log and, when this app
/// runs one, the acpmux daemon's (``OwnerPanicForwarder``).
///
/// ``start()`` starts each on its own queue now. ``run()`` does the same work on the calling thread, which
/// may block on files, and ``post(on:)`` posts it as one afterStartup best-effort files-lane task, so it waits
/// for startup completion and the best-effort fence (feature `crashForwardersAfterStartup`, p08-startup-078), as
/// Chrome posts non-critical startup work with `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc) to a BEST_EFFORT ThreadPool runner. Either way the first pass
/// sends what the last run left: each forwarder keeps its watermark or offset across runs, so a report written
/// before the first pass of this launch is sent by it.
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
    /// The cmux-tui owner's panic log forwarder.
    public let ownerPanics: OwnerPanicForwarder
    private let makeAcpmuxPanics: @Sendable () -> OwnerPanicForwarder?
    /// The acpmux forwarder once made, kept for the process's life: its folder watch lives as long as it does.
    private let acpmux = Mutex<OwnerPanicForwarder?>(nil)

    /// - Parameters:
    ///   - system: The helper crash report forwarder.
    ///   - ownerPanics: The owner's panic log forwarder.
    ///   - acpmuxPanics: Makes the acpmux daemon's panic log forwarder, or nil with no acpmux; called once, by
    ///     ``start()`` or ``run()``, because finding acpmux reads the file system.
    public init(system: SystemCrashForwarder, ownerPanics: OwnerPanicForwarder,
                acpmuxPanics: @escaping @Sendable () -> OwnerPanicForwarder?) {
        self.system = system
        self.ownerPanics = ownerPanics
        makeAcpmuxPanics = acpmuxPanics
    }

    /// The acpmux daemon's panic log forwarder, once ``start()`` or ``run()`` made it.
    public var acpmuxPanics: OwnerPanicForwarder? { acpmux.withLock { $0 } }

    /// Starts every forwarder on its own queue. Call it, or ``run()``, once.
    public func start() {
        system.start()
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
        system.forwardAndWatch()
        ownerPanics.forwardAndWatch()
        makeAcpmux()?.forwardAndWatch()
    }

    private func makeAcpmux() -> OwnerPanicForwarder? {
        guard let forwarder = makeAcpmuxPanics() else { return nil }
        acpmux.withLock { $0 = forwarder }
        return forwarder
    }
}
