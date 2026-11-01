public import CmuxSentryReporting
public import Darwin
public import Foundation
public import Sentry
public import CmuxNextCompat

/// Sends cmux-next crashes (signals, Mach exceptions, uncaught Objective-C
/// exceptions, app hangs) to Sentry, under ``CrashReportingPolicy``.
///
/// Same options as the main app (`AppDelegate`): no default PII, no
/// performance tracing (its root transaction cannot be scrubbed), 8 s app
/// hangs, every event, breadcrumb and span through `SentryEventScrubber`.
/// No structured logs: cmux-next has no log bridge, so it sends nothing the
/// main app does not.
///
/// Signal order. Start after the run marker installs its handlers
/// (`AppRunMarker`): Sentry saves them as the previous handlers and calls
/// them after its report. Chromium resets every signal action at its start;
/// call ``reassertSignalHandlers()`` after the run marker installs its
/// handlers again.
public final class CrashReporter: Sendable {
    /// The DSN of the macOS app's Sentry project (`manaflow/cmuxterm-macos`),
    /// as in the main app; cmux-next events are told apart by
    /// ``CrashEventLabels``.
    public static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
    /// Signals Sentry handles as crashes.
    public static let fatalSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP]
    /// Signals the app owns and Sentry's start must not take: SIGPIPE is a
    /// no-op handler (`ChildSignalDefaults`), SIGTERM a requested quit.
    public static let appOwnedSignals: [Int32] = [SIGPIPE, SIGTERM]

    public let policy: CrashReportingPolicy
    private let sentryHandlers = Mutex<SignalActions?>(nil)
    // Lock carve-out: Sentry's beforeSend reads it synchronously on its own
    // thread; a sign-in writes it from the main thread.
    private let identityState: Mutex<CrashReportIdentity>

    /// - Parameters:
    ///   - policy: Whether this launch reports, and its labels.
    ///   - identity: The install id and commit every event is tagged with.
    public init(policy: CrashReportingPolicy, identity: CrashReportIdentity = CrashReportIdentity()) {
        self.policy = policy
        self.identityState = Mutex(identity)
    }

    /// This launch's hourly counts of main-thread stalls and hangs
    /// (``StallSummaryRecorder``): the watchdog's sinks record into it;
    /// call ``StallSummaryRecorder/close()`` at quit.
    public let stallSummary = StallSummaryRecorder.sentry()

    /// The install, commit and team member tags every event carries now.
    public var identity: CrashReportIdentity { identityState.withLock { $0 } }

    /// Names (or stops naming) the signed-in cmux team member on every later
    /// event. Call when the account or its teams change.
    /// - Parameter member: The member, or nil for an anonymous report.
    public func setTeamMember(_ member: CrashTeamMember?) {
        identityState.withLock { $0.member = member }
    }

    /// Follows `members` (one value per sign-in, sign-out or team change) for
    /// the app's lifetime: each value names, or stops naming, the member.
    /// - Parameter members: The signed-in cmux team member over time.
    public func followTeamMembers(_ members: ObservationStream<CrashTeamMember?>) {
        // task-owner: lives for the app; ends when `members` ends.
        Task { [self] in
            for await member in members { setTeamMember(member) }
        }
    }

    /// Whether Sentry runs in this process.
    public var isStarted: Bool { sentryHandlers.withLock { $0 != nil } }

    /// The Sentry options for ``policy``.
    public func options() -> Options {
        let options = Options()
        options.dsn = Self.dsn
        options.environment = policy.environment
        options.releaseName = policy.release
        options.dist = policy.dist
        options.debug = false
        options.sendDefaultPii = false
        options.tracesSampleRate = 0.0
        options.appHangTimeoutInterval = 8.0
        options.attachStacktrace = true
        options.enableCaptureFailedRequests = false
        // Objective-C exceptions that reach NSApplication's reportException:
        // hook, with their reason and throw stack (main d481d516e520). The
        // SDK also registers NSApplicationCrashOnExceptions, which every
        // channel already registers (cx-r3q, CrashOnExceptions).
        options.enableUncaughtNSExceptionReporting = policy.crashesOnExceptions
        options.enableLogs = false
        let scrubber = SentryEventScrubber()
        let labels = CrashEventLabels(policy: policy)
        options.beforeSend = { [self] event in
            let scrubbed = scrubber.scrub(event)
            labels.apply(to: scrubbed, identity: identity)
            return scrubbed
        }
        options.beforeBreadcrumb = { breadcrumb in scrubber.scrub(breadcrumb) }
        options.beforeSendSpan = { span in scrubber.scrub(span) }
        return options
    }

    /// Starts Sentry when the policy allows it. Call once, on the main
    /// thread, after the run marker's handlers are installed.
    /// - Returns: whether Sentry started.
    @discardableResult
    public func start() -> Bool {
        guard policy.shouldStart, !isStarted else { return false }
        // The main app's startup race (#836): Sentry's init thread reads the
        // environment while the main thread first builds the locale.
        _ = Locale.current
        _ = NSLocale.preferredLanguages
        let appOwned = SignalActions(capturing: Self.appOwnedSignals)
        TaskExceptionPorts.captureBeforeSentry()
        SentrySDK.start(options: options())
        TaskExceptionPorts.noteSentryStarted()
        appOwned.restore()
        let handlers = SignalActions(capturing: Self.fatalSignals)
        sentryHandlers.withLock { $0 = handlers }
        return true
    }

    /// Puts Sentry's fatal-signal handlers back after something reset them
    /// (Chromium's start). Sentry still calls the handlers it saved at
    /// start after its report.
    public func reassertSignalHandlers() {
        sentryHandlers.withLock { $0 }?.restore()
    }

    /// Gives back the Mach exception ports Sentry took at start while its
    /// port is still registered (``TaskExceptionPorts``): a fault that runs
    /// again after a fatal-signal handler returns then reaches the system's
    /// handler and ends the process, instead of waiting forever on a port
    /// whose receiver thread Sentry ended. Async-signal-safe; for
    /// fatal-signal handlers.
    public static func releaseSentryExceptionPorts() {
        TaskExceptionPorts.restoreIfSentryOwned()
    }

    /// Starts the crash deadline thread (``CrashDeadline``). Call once at
    /// launch, before the handlers that call ``beginCrashDeadline()``.
    public static func installCrashDeadline() {
        CrashDeadline.install()
    }

    /// Starts the out-of-process crash watcher (``CrashWatcher``, #22844) off
    /// the main thread. Call once at launch, after ``installCrashDeadline()``.
    /// - Parameter sampleFile: Where the watcher writes its `sample` of an app
    ///   it ends.
    public static func installCrashWatcher(sampleFile: String) {
        CrashWatcher.install(sampleFile: sampleFile)
    }

    /// A crash has begun: the process ends within ``CrashDeadline/seconds``
    /// even if the crash path blocks, and within ``CrashWatcher/defaultSeconds``
    /// even if every thread of the app is suspended. Async-signal-safe.
    public static func beginCrashDeadline() {
        CrashDeadline.arm()
        CrashWatcher.arm()
    }

    /// A crash path that blocks while every thread is suspended, for the crash
    /// gate's `debug.crash.app {"signal": "suspended"}` only (#22844): begins
    /// the crash path, suspends the crash deadline's thread (as Sentry's report
    /// writer does) and blocks the calling thread forever. Only
    /// ``CrashWatcher`` can end the process.
    public static func blockWithDeadlineSuspended() -> Never {
        beginCrashDeadline()
        CrashDeadline.suspendThread()
        // A semaphore nothing signals: the blocked crash path the watcher must end.
        var never = semaphore_t(0)
        _ = semaphore_create(mach_task_self_, &never, SYNC_POLICY_FIFO, 0)
        // concurrency-allow: crash-gate debug verb; blocking forever is the crash it simulates.
        _ = semaphore_wait(never)
        abort()
    }

    /// The first call of a fatal-signal handler: gives back Sentry's
    /// exception ports, then starts the crash deadline. Async-signal-safe.
    public static func fatalSignalBegan() {
        releaseSentryExceptionPorts()
        beginCrashDeadline()
    }

    /// `NSApplication.reportException(_:)`: with crashing on (`crashes`) the
    /// crash has begun and the deadline starts. With it off (the user's own
    /// setting) AppKit logs the exception and survives; Sentry's hook still
    /// calls the uncaught-exception handler, which must then not start the
    /// deadline (``uncaughtException(_:then:)``). `record` writes the app's
    /// exception record, `report` is AppKit's reportException.
    public static func reportException(_ exception: NSException, crashes: Bool,
                                       record: (NSException) -> Void, report: () -> Void) {
        if crashes { beginCrashDeadline() }
        record(exception)
        reportingSurvivableException.store(!crashes, ordering: .releasing)
        defer { reportingSurvivableException.store(false, ordering: .releasing) }
        report()
    }

    /// The uncaught-exception handler: the runtime aborts after it, so the
    /// crash has begun, unless Sentry's reportException: hook calls it for
    /// an exception AppKit survives. Then `record`.
    public static func uncaughtException(_ exception: NSException, then record: (NSException) -> Void) {
        if !(Thread.isMainThread && reportingSurvivableException.load(ordering: .acquiring)) { beginCrashDeadline() }
        record(exception)
    }

    /// `debug.crash.app {"signal": "frozen"}`: starts the crash path, then
    /// points the task's EXC_BREAKPOINT exception port at a new port that no
    /// thread receives on, so the next trap waits for a reply forever (the
    /// 2026-10-20 freezes); only the crash deadline ends it.
    public func freezeNextTrap() {
        Self.beginCrashDeadline()
        let task = mach_task_self_
        var port = mach_port_t(0)
        guard mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS,
              mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else { return }
        _ = task_set_exception_ports(task, exception_mask_t(EXC_MASK_BREAKPOINT), port,
                                     exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
    }

    /// The main thread is inside `reportException:` for an exception AppKit survives.
    private static let reportingSurvivableException = Atomic<Bool>(false)

    /// Records a non-fatal product failure (a warning event tagged `failure`)
    /// so a user action that silently did nothing shows up in the crash
    /// telemetry. `message` must hold no user content: it is sent as is.
    public func recordFailure(_ name: String, message: String) {
        guard isStarted else { return }
        SentrySDK.capture(message: "\(name): \(message)") { scope in
            scope.setTag(value: name, key: "failure")
            scope.setLevel(.warning)
        }
    }

    /// Sends a handled, non-fatal error event (a guard that caught a
    /// problem before it crashed the app). One issue per `fingerprint`.
    /// Does nothing while Sentry is off (consent, debug build).
    public func captureNonFatal(_ message: String, type: String, fingerprint: [String], tags: [String: String] = [:],
                                extra: [String: String] = [:]) {
        guard isStarted else { return }
        let event = Event(level: .error)
        let exception = Exception(value: message, type: type)
        let mechanism = Mechanism(type: "cmux_guard")
        mechanism.handled = true
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.message = SentryMessage(formatted: message)
        event.fingerprint = fingerprint
        event.tags = tags
        event.extra = extra
        SentrySDK.capture(event: event)
    }

    /// Tags the current scope so a crash this process causes on purpose
    /// (`debug.crash.app`, `debug.crash.exception`) can be filtered out.
    public func markDeliberateCrash(_ name: String) {
        guard isStarted else { return }
        SentrySDK.configureScope { scope in scope.setTag(value: name, key: "deliberate_crash") }
    }
}
