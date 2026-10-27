public import CmuxNextTrace
public import CmuxSentryReporting
public import CmuxSentryScrubbing
public import Darwin
public import Foundation
public import Sentry
import CmuxNextCompat

/// Sends cmux-next crashes (signals, Mach exceptions, uncaught Objective-C
/// exceptions, app hangs) to Sentry, under ``CrashReportingPolicy``.
///
/// Same options as the main app (`AppDelegate`): no default PII, no
/// performance tracing (its root transaction cannot be scrubbed), every
/// event, breadcrumb and span through `SentryEventScrubber`. No structured
/// logs: cmux-next has no log bridge, so it sends nothing the main app does
/// not. App hangs come from ``HangTracking``.
///
/// Idle cost (p09-observability-076). On macOS the SDK's app-hang tracker
/// (`SentryANRTrackerV1`) is a thread that posts a block to the main queue
/// every `appHangTimeoutInterval / 5` (1.6 s at 8 s), idle or not: 0.625 main
/// wakeups per second. Chrome's HangWatcher wakes for nothing while no scope
/// is open (base/threading/hang_watcher.cc), and neither does the main-thread
/// watchdog that reports cmux-next's hangs, so the tracker is off whenever
/// the fatal-hang record covers the hang the app does not survive
/// (``HangTracking/watchdog``). Every other option that would add an
/// integration, a swizzle or a wakeup is set here and checked against
/// `CLISentryRuntimePolicy` by `CrashReporterOptionsTests`.
///
/// Signal order. Start after the run marker installs its handlers
/// (`AppRunMarker`): Sentry saves them as the previous handlers and calls
/// them after its report. Chromium resets every signal action at its start;
/// call ``reassertSignalHandlers()`` after the run marker installs its
/// handlers again.
///
/// Start cost (p08-startup-032). `SentrySDK.start` on main installs every
/// integration in that call; the SDK (sentry-cocoa 9.28) has no public API
/// to install one later. Session tracking already does its file I/O on the
/// SDK's own queue, and network breadcrumbs stay on for the whole run. So
/// ``StartProfile/handlersFirst`` changes no option: it only pauses app-hang
/// reports until ``resumeAfterStartup()``. The app's `crash.sentry_start`
/// and `crash.sentry_started` launch marks bound the call
/// (`LaunchSignposts.Interval.sentryStart`).
public final class CrashReporter: Sendable {
    /// What `SentrySDK.start` turns on at launch.
    public nonisolated enum StartProfile: Sendable, Equatable {
        /// Every integration the options allow, reporting from the start.
        case standard
        /// The same integrations, but app-hang reports wait for startup (feature `sentryHandlersFirst`):
        /// paused until ``CrashReporter/resumeAfterStartup()``; the main-thread watchdog reports launch
        /// hangs. Crash capture, sessions and breadcrumbs are as in ``standard``. With
        /// ``HangTracking/watchdog`` there is no app-hang tracker to pause.
        case handlersFirst
    }

    /// The DSN of the macOS app's Sentry project (`manaflow/cmuxterm-macos`),
    /// as in the main app; cmux-next events are told apart by
    /// ``CrashEventLabels``.
    public static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
    /// Signals Sentry handles as crashes.
    public static let fatalSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP]
    /// Signals the app owns and Sentry's start must not take: SIGPIPE is a
    /// no-op handler (`ChildSignalDefaults`), SIGTERM a requested quit.
    public static let appOwnedSignals: [Int32] = [SIGPIPE, SIGTERM]

    /// Which part of the app reports main-thread hangs.
    public nonisolated enum HangTracking: Sendable, Equatable {
        /// Sentry's app-hang tracker, 8 s: the only report of a hang the app does not survive. Its thread
        /// wakes the main queue every 1.6 s for the whole run.
        case sentry
        /// The main-thread watchdog reports each hang (`MainThreadWatchdog.onHang`) and keeps the fatal-hang
        /// record the next launch reports (p09-observability-110); Sentry's tracker is off. The app sets both
        /// sinks before ``CrashReporter/start(profile:)`` (`WatchdogHangSinks`), so a launch hang is reported too.
        case watchdog

        /// The launch's choice: ``watchdog`` once the fatal-hang record is kept (feature `fatalHangReports`).
        public init(fatalHangRecordOn: Bool) {
            self = fatalHangRecordOn ? .watchdog : .sentry
        }
    }

    public let policy: CrashReportingPolicy
    public let hangTracking: HangTracking
    /// The previous run's crash keys and black box, put on its crash event at this launch (task 079).
    public let previousRun: PreviousRunCrashEvidence?
    private let sentryHandlers = Mutex<SignalActions?>(nil)

    /// - Parameter previousRun: The previous run's files, read when its crash event is sent; nil after a clean
    ///   exit or outside the app process.
    public init(policy: CrashReportingPolicy, hangTracking: HangTracking = .sentry, previousRun: PreviousRunCrashEvidence? = nil) {
        self.policy = policy
        self.hangTracking = hangTracking
        self.previousRun = previousRun
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
        // No tracing, so no auto-instrumentation: network, file I/O and Core Data spans stay off even if a
        // sample rate is set later.
        options.enableAutoPerformanceTracing = false
        options.enableAppHangTracking = hangTracking == .sentry
        options.appHangTimeoutInterval = 8.0
        // MetricKit's hang, CPU and disk diagnostics repeat what the watchdog and the system crash forwarder
        // send; the SDK turns it on by default in v10.
        options.enableMetricKit = false
        // Swizzling stays on for the two macOS hooks that need it: uncaught NSException reports (NSApplication
        // reportException:) and URLSession breadcrumbs. With tracing off the SDK installs no other swizzle, and
        // its breadcrumb tracker only observes NSApplication notifications (no timer).
        options.enableSwizzling = true
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
        let previousRun = previousRun
        // The hint form of beforeSend: only its hint can add an attachment to one event (the previous run's
        // crash). The previous run's tags go on before the scrub, so they are scrubbed with the rest.
        options.beforeSendWithHint = { event, hint in
            previousRun?.decorate(event, hint: hint)
            let scrubbed = scrubber.scrub(event)
            labels.apply(to: scrubbed)
            return scrubbed
        }
        options.beforeBreadcrumb = { breadcrumb in scrubber.scrub(breadcrumb) }
        options.beforeSendSpan = { span in scrubber.scrub(span) }
        return options
    }

    /// Starts Sentry when the policy allows it. Call once, on the main
    /// thread, after the run marker's handlers are installed.
    /// - Parameter profile: With ``StartProfile/handlersFirst``, call
    ///   ``resumeAfterStartup()`` once startup completes.
    /// - Returns: whether Sentry started.
    @discardableResult
    public func start(profile: StartProfile = .standard) -> Bool {
        guard policy.shouldStart, !isStarted else { return false }
        // The main app's startup race (#836): Sentry's init thread reads the
        // environment while the main thread first builds the locale.
        _ = Locale.current
        _ = NSLocale.preferredLanguages
        let appOwned = SignalActions(capturing: Self.appOwnedSignals)
        let exceptionPorts = TaskExceptionPorts.captureBeforeSentry()
        SentrySDK.start(options: options())
        if profile == .handlersFirst { SentrySDK.pauseAppHangTracking() }
        TaskExceptionPorts.noteSentryStarted(exceptionPorts)
        appOwned.restore()
        let handlers = SignalActions(capturing: Self.fatalSignals)
        sentryHandlers.withLock { $0 = handlers }
        return true
    }

    /// The part of a ``StartProfile/handlersFirst`` start that waits for
    /// startup: app-hang reports resume. Call once, on main, after startup
    /// completes; does nothing while Sentry is off.
    public func resumeAfterStartup() {
        guard isStarted else { return }
        SentrySDK.resumeAppHangTracking()
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
    /// Each crash path then writes its own record, then the crash keys
    /// (``recordCrashKeys()``).
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
        recordCrashKeys()
        CrashDeadline.suspendThread()
        // A semaphore nothing signals: the blocked crash path the watcher must end.
        var never = semaphore_t(0)
        // SAFETY: semaphore_create writes one semaphore name into `never`, a local live for the call.
        _ = unsafe semaphore_create(mach_task_self_, &never, SYNC_POLICY_FIFO, 0)
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
        if crashes { recordCrashKeys() }
        reportingSurvivableException.store(!crashes, ordering: .releasing)
        defer { reportingSurvivableException.store(false, ordering: .releasing) }
        report()
    }

    /// The uncaught-exception handler: the runtime aborts after it, so the
    /// crash has begun, unless Sentry's reportException: hook calls it for
    /// an exception AppKit survives. Then `record`.
    public static func uncaughtException(_ exception: NSException, then record: (NSException) -> Void) {
        let crashes = !(Thread.isMainThread && reportingSurvivableException.load(ordering: .acquiring))
        if crashes { beginCrashDeadline() }
        record(exception)
        if crashes { recordCrashKeys() }
    }

    /// `debug.crash.app {"signal": "frozen"}`: starts the crash path, then
    /// points the task's EXC_BREAKPOINT exception port at a new port that no
    /// thread receives on, so the next trap waits for a reply forever (the
    /// 2026-10-20 freezes); only the crash deadline ends it.
    public func freezeNextTrap() {
        Self.beginCrashDeadline()
        // The frozen trap never reaches a signal handler: the keys go now.
        Self.recordCrashKeys()
        let task = mach_task_self_
        var port = mach_port_t(0)
        // SAFETY: mach_port_allocate writes one port name into `port`, a local live for the call.
        guard unsafe mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS,
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

    /// The previous run's black box as the crash event's `blackbox.txt` (p09-observability-128, 079): nil without
    /// the hang-reports opt-in, never a key-timing, per-key PTY or flow record (``TraceBlackBoxUpload``), and
    /// passed through `scrubber` like every other text that leaves the Mac.
    public static func blackboxAttachment(_ records: [TraceBlackBoxUpload.Record], hangReportsOptIn: Bool,
                                          scrubber: SentryScrubber = SentryScrubber()) -> Attachment? {
        guard let text = TraceBlackBoxUpload().crashAttachmentText(records, hangReportsOptIn: hangReportsOptIn) else {
            return nil
        }
        return Attachment(data: Data(scrubber.scrub(text).utf8), filename: blackboxFileName, contentType: "text/plain")
    }

    /// The black box attachment's file name.
    public static let blackboxFileName = "blackbox.txt"

    /// Tags the current scope so a crash this process causes on purpose
    /// (`debug.crash.app`, `debug.crash.exception`) can be filtered out.
    public func markDeliberateCrash(_ name: String) {
        guard isStarted else { return }
        SentrySDK.configureScope { scope in scope.setTag(value: name, key: "deliberate_crash") }
    }
}
