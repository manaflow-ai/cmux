import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import Darwin
import Foundation
import os

/// Descriptor the fatal-signal handler writes the signal number into.
// crash-allow: signal-handler state, an aligned Int32 with a constant initial value (an Atomic would run its lazy initializer in the handler); set on the main thread before installHandlers, then cleared once by the handler or a clean exit.
nonisolated(unsafe) private var fatalSignalDescriptor: Int32 = -1

/// Writes the signal number ("11\n") with one async-signal-safe write(2),
/// then lets the signal end the process with its default action:
/// - a fault (SEGV, BUS, ILL, FPE, TRAP from the CPU, SYS from a bad system
///   call): return, so the faulting instruction runs again under SIG_DFL
///   and macOS writes its crash report (re-raising here made the end a
///   plain signal with no report);
/// - any other signal, or one sent by a process or by raise/abort (SIGTERM,
///   SIGINT, SIGHUP, abort's SIGABRT): re-raise it, or it would be lost.
///
/// On Darwin arm64 `si_code` cannot tell them apart (XNU never reports `SI_USER`, cx-sjv65), so a
/// signal that arrives as a system call returns (raised, or sent to a waiting thread) is re-raised.
/// One sent to a thread running user code still reads as a fault and is lost, as before.
///
/// First `fatalSignalBegan` gives back Sentry's Mach exception ports (the
/// fault that runs again must reach the system's handler) and starts the
/// crash deadline (2026-10-20 freezes). The crash keys (`run.crashkeys`)
/// are written after the signal number.
private let fatalSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    CrashReporter.fatalSignalBegan()
    var bytes: (UInt8, UInt8, UInt8) = (UInt8(48 + (signal / 10) % 10), UInt8(48 + signal % 10), 10)
    let descriptor = fatalSignalDescriptor
    if descriptor >= 0 {
        // Only the first signal is recorded (abort() may follow a raise).
        fatalSignalDescriptor = -1
        // concurrency-allow: signal handler context (the process is ending), one 3-byte write to a local file.
        // SAFETY: the view covers the 3-byte local tuple for the closure, and write(2) reads exactly those 3 bytes.
        _ = unsafe withUnsafeBytes(of: &bytes) { unsafe Darwin.write(descriptor, $0.baseAddress, 3) }
    }
    // After run.signal: a fault in here re-runs under SIG_DFL and still leaves the signal recorded.
    CrashReporter.recordCrashKeys()
    _ = Darwin.signal(signal, SIG_DFL)
    // SAFETY: with SA_SIGINFO the kernel passes a siginfo_t (or none) and the thread's ucontext_t, both live on
    // the signal stack for the handler's run; they are only read here.
    let sentBySoftware = unsafe info.map { unsafe $0.pointee.si_code == SI_USER || $0.pointee.si_code == SI_QUEUE } ?? true
        || arrivedOnASystemCall(context)
    let fault = signal == SIGSEGV || signal == SIGBUS || signal == SIGILL || signal == SIGFPE || signal == SIGTRAP || signal == SIGSYS
    if sentBySoftware || !fault { _ = raise(signal) }
}

/// Whether the thread was returning from `svc #0x80`: syndrome class 0x15 and that word before the pc.
/// Sentry's re-raise arrives on the `sigreturn` to the faulting pc, which may be unmapped, so the
/// word is read with `vm_read_overwrite` and a failed read is a fault. No context re-raises.
nonisolated func arrivedOnASystemCall(_ context: UnsafeMutableRawPointer?) -> Bool {
    #if arch(arm64)
    // SAFETY: `context` is the ucontext_t the kernel passed the SA_SIGINFO handler, live for its run, and
    // its uc_mcontext points at the thread's saved state in the same frame; both are only read.
    guard let state = unsafe context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext else { return true }
    guard unsafe state.pointee.__es.__esr >> 26 == 0x15 else { return false }
    let pc = unsafe UInt(state.pointee.__ss.__pc)
    guard pc >= 4 else { return false }
    var word: UInt32 = 0, read: vm_size_t = 0
    // SAFETY: vm_read_overwrite copies at most the 4 bytes asked for into `word`, a local of 4 bytes live for the
    // call, and writes the count into `read`; an unmapped pc fails the read instead of faulting.
    let result = unsafe withUnsafeMutablePointer(to: &word) {
        unsafe vm_read_overwrite(mach_task_self_, vm_address_t(pc - 4), 4, vm_address_t(UInt(bitPattern: $0)), &read)
    }
    return result == KERN_SUCCESS && read == 4 && word == 0xD400_1001
    #else
    return false
    #endif
}

/// Marks this run as live, so the next launch can tell a crash from a normal quit (`LaunchRecovery`). Per bundle id,
/// so tagged builds never read each other's marker.
///
/// - `run.json`: pid, launch time, whether this run is a restart, whether it lived past the quick-crash window, and
///   whether a requested quit had begun (`markQuitting`); whether its startup completed, the last startup task it
///   began before that, and the runs in a row before it that ended before theirs (`LaunchSafeMode`, ``observe(_:)``).
/// - `run.launch`: this launch's streak, written before any launch cache is read (`LaunchSafeMode.Beacon`).
/// - `run.signal`: empty until a fatal signal handler writes its number.
///
/// A normal quit removes both. A quit that had begun, or a requested-quit signal
/// (`LaunchRecovery.requestedQuitSignals`), counts as a quit that was asked for, even when the process is then killed
/// before it ends.
///
/// The launch read (``startLaunchRead(directory:in:now:bootSession:)``) reads the previous run's files and opens this
/// run's crash files under spare names on the files lane, changing none of the previous run's: a launch that ends
/// before the marker is made (``init(launch:)``) leaves the next one the same decision. The marker's background
/// writer (`RunMarkerFile`) then gives the crash files their names and writes `run.json`; the quit path awaits its
/// `quitting` write (`markQuitting`).
/// The launch read also makes the launch caches' crash-streak decision (``safeMode``) when no cache read made it
/// first; a cache that ends a launch before its marker is made is counted by that launch's `run.launch`.
@MainActor
final class AppRunMarker {
    private let directory: URL
    private let file: RunMarkerFile
    private var marker: PreviousRun
    /// The ticket of the newest submitted write.
    private var lastTicket: UInt64 = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    /// Marks the run survived once it lived past the quick-crash window (``armSurvivalWindow(on:now:)``).
    private var survival: MainDeadline?

    /// How this launch follows the previous run.
    let recovery: LaunchRecovery
    /// How the previous run ended when it did not quit as asked (stability.unclean_exit, task 109); nil after a
    /// normal or requested quit, or on a first launch.
    let previousExit: HistogramID.UncleanExit?
    /// The previous run as its marker left it, whatever its end; nil on a first launch. Its crash event, sent at
    /// this launch, gets its crash keys and black box (`AppCrashReporting`).
    let previousRun: PreviousRun?
    /// The previous run when it ended with no handler of its own (killed, or the Mac shut down), so no crash report
    /// covers it; its fatal-hang record, if any, is reported. Nil after a quit, a crash or none.
    let previousUnreported: PreviousRun?
    /// The crash keys the previous run's crash path wrote (`run.crashkeys`), read by the launch read; nil when that
    /// run ended with no crash path (a normal quit, SIGKILL, power loss) or on a first launch.
    let previousCrashKeys: CrashKeys?
    /// Whether this launch reads the launch caches: not after a streak of runs that ended before their startup
    /// completed.
    let safeMode: LaunchSafeMode
    private var exceptionFile: URL { directory.appending(path: "run.exception") }

    /// The app's marker folder for `bundleID`.
    static func standardDirectory(bundleID: String?) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux-next", directoryHint: .isDirectory)
            .appending(path: CrashReportWriter.safe(bundleID ?? "unknown"), directoryHint: .isDirectory)
    }

    /// What the marker's launch read did on the files lane (``startLaunchRead(directory:in:now:bootSession:)``): the
    /// previous run's files, read and left in place, and the files this run's crash path writes to, open under spare
    /// names (``spareSignalName``, ``spareCrashKeysName``) until ``AppRunMarker/init(launch:)`` gives them theirs.
    /// Chrome reads its clean-exit beacon off the UI thread before the main loop runs and marks the new session
    /// unclean later, not in that read (components/metrics/clean_exit_beacon.cc, `CleanExitBeacon::WriteBeaconValue`).
    nonisolated struct Launch: Sendable {
        /// The marker folder, and this boot's id (``currentBootSession()``) asked on the lane.
        let directory: URL, bootSession: String?
        /// The previous run's `run.json` with its `run.signal` and `run.exception` (nil on a first launch or when
        /// `run.json` does not decode), and its `run.crashkeys` record (``readCrashKeys(_:)``).
        let previous: PreviousRun?, previousCrashKeys: CrashKeys?
        /// This run's marker, which ``AppRunMarker/init(launch:)`` writes as `run.json` when ``failure`` is nil.
        let marker: PreviousRun
        /// Why the marker folder could not be made; nil when it exists. With a failure no file is open.
        let failure: String?
        /// This run's `run.signal` and `run.crashkeys`, open and empty under their spare names; -1 if not open.
        let signalDescriptor: Int32, keysDescriptor: Int32
        /// The launch caches' crash-streak decision (``AppRunMarker/launchSafeMode(directory:now:bootSession:processStart:)``).
        var safeMode: LaunchSafeMode = .noStreak
        /// How this launch follows the previous run.
        var recovery: LaunchRecovery { LaunchRecovery.decide(previous: previous?.forRecovery(bootSession: bootSession)) }
        /// How the previous run ended when it did not quit as asked; nil after a normal or requested quit, or on a first launch.
        var previousExit: HistogramID.UncleanExit? { previous?.uncleanExit(bootSession: bootSession) }
        /// The previous run when no crash report covers its end (``PreviousRun/unreported(bootSession:)``).
        var previousUnreported: PreviousRun? { previous?.unreported(bootSession: bootSession) }
    }

    /// Takes the marker's launch read (``startLaunchRead(directory:in:now:bootSession:)``, which read the previous
    /// run's files and opened this run's on the files lane): decides how this launch follows the previous run, marks
    /// this run live and installs the fatal-signal handlers. No file call on the main thread.
    init(launch: Launch) {
        directory = launch.directory
        // A normal quit removes `run.launch` with `run.json`: left alone it would read as a launch that ended before its marker.
        file = RunMarkerFile(url: launch.directory.appending(path: "run.json"), signalURL: launch.directory.appending(path: "run.signal"),
                             beaconURL: launch.directory.appending(path: Self.beaconName))
        (previousExit, recovery, previousCrashKeys) = (launch.previousExit, launch.recovery, launch.previousCrashKeys)
        previousRun = launch.previous
        previousUnreported = launch.previousUnreported
        (marker, safeMode) = (launch.marker, launch.safeMode)
        start(launch)
    }

    /// This process's kernel start in Unix microseconds (one `proc_pidinfo`), the value its black box and
    /// crash-key page headers carry; nil when the kernel does not give it.
    nonisolated static func currentProcessStart() -> UInt64? {
        let start = TraceRingCleanup.processStartUnixMicros(pid: getpid())
        return start == 0 ? nil : start
    }

    /// Records the launch's startup in `run.json`: the name of each main task `startup` begins before it completes,
    /// then the completion, which resets ``LaunchSafeMode``'s streak for the next launch. Each record is one queued
    /// write, encoded off the main thread and coalesced (``RunMarkerFile``).
    func observe(_ startup: StartupScheduler) {
        startup.taskStarted = { [weak self] name in self?.startupTaskStarted(name) }
        startup.whenComplete { [weak self] _ in self?.startupCompleted() }
    }

    /// The startup main task `name` began (``observe(_:)``).
    func startupTaskStarted(_ name: StaticString) {
        marker.lastStartupTask = name.description
        writeMarker()
    }

    /// Startup completed (``observe(_:)``): the next launch reads its caches again.
    func startupCompleted() {
        guard marker.startupComplete != true else { return }
        marker.startupComplete = true
        marker.incompleteLaunches = 0
        writeMarker()
    }

    /// This boot's id, `kern.bootsessionuuid` as 32 hex digits; nil when the kernel does not give it.
    nonisolated static func currentBootSession() -> String? {
        let bytes = TraceBlackBox.ProcessFacts.current().bootSessionUUID
        guard !bytes.isEmpty else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func start(_ launch: Launch) {
        // First, before any crash handler is installed (the uncaught-exception recorder below, the crash deadline,
        // the fatal-signal handlers) and whether or not the files opened: the crash keys' block, which those
        // handlers read (CrashKeys).
        CrashReporter.prepareCrashKeysBlock()
        if let failure = launch.failure {
            logger.error("run marker not started: \(failure, privacy: .public)")
            return
        }
        // On the writer's queue, before this run's first marker: this run's open crash files replace the previous
        // run's record, and the exception recorder gets its file once the previous run's is gone.
        let exceptionFile = exceptionFile
        file.enqueue { [launch] in
            AppRunMarker.takeOverCrashFiles(of: launch)
            UncaughtExceptionRecorder.record(into: exceptionFile)
        }
        writeMarker()
        UncaughtExceptionRecorder.install()
        guard launch.signalDescriptor >= 0 else { return }
        fatalSignalDescriptor = launch.signalDescriptor
        // The crash path writes this run's crash keys into the file the launch read opened (CrashKeys).
        if launch.keysDescriptor >= 0 { CrashReporter.prepareCrashKeysRecord(descriptor: launch.keysDescriptor) }
        CrashReporter.installCrashDeadline()
        CrashReporter.installCrashWatcher(sampleFile: directory.appending(path: "crash-watcher-sample.txt").path)
        installHandlers()
    }

    /// Starts the quick-crash window: the run is marked survived once it has lived
    /// ``LaunchRecovery/quickCrashWindow`` since its launch. One background deadline on the app's scheduler (nobody
    /// waits on it, and a crash before it fires leaves the run unsurvived); a clean exit cancels it. Armed once.
    func armSurvivalWindow(on deadlines: MainDeadlineScheduler, now: Date = Date()) {
        guard survival == nil else { return }
        let deadline = MainDeadline(owner: "AppRunMarker.survival", workClass: .background, scheduler: deadlines)
        survival = deadline
        let lived = Duration.seconds(max(0, now.timeIntervalSince(marker.launched)))
        deadline.schedule(after: max(.zero, LaunchRecovery.quickCrashWindow - lived)) { [weak self] in self?.markSurvived() }
    }

    /// Installs the fatal signal handlers. Call again after CefInitialize: Chromium resets these signals to their
    /// default action at start. They run on the faulting thread's alternate signal stack, so a stack overflow is
    /// recorded too: the main thread's, and one on every thread started after the first call.
    func installHandlers() {
        guard fatalSignalDescriptor >= 0 else { return }
        CrashReporter.installAlternateSignalStacks()
        // SIGTERM, SIGINT and SIGHUP are requested quits: `QuitSignal` turns them into "Quit, keep sessions" once
        // installed; until then this handler records them.
        let fatal = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS]
        let signals = QuitSignal.isInstalled ? fatal : fatal + LaunchRecovery.requestedQuitSignals.sorted()
        for signal in signals {
            var action = sigaction()
            // SAFETY: the handler is a C function of the SA_SIGINFO signature, set in the union member that
            // SA_SIGINFO selects; sigemptyset and sigaction read and write `action`, a local live for the calls,
            // and the kernel copies it (no old action asked for).
            unsafe action.__sigaction_u.__sa_sigaction = fatalSignalHandler
            action.sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK
            unsafe sigemptyset(&action.sa_mask)
            unsafe sigaction(signal, &action, nil)
        }
        QuitSignal.reclaim()
    }

    private func markSurvived() {
        marker.survived = true
        writeMarker()
    }

    /// A requested quit has begun (`QuitCoordinator`): the next launch is clean even if this process is killed before
    /// the quit finishes, for example by dev tooling's SIGKILL after its bounded wait while Chromium shuts down.
    /// Returns once `quitting` is on disk, or false after `timeout` (the quit goes on either way).
    @discardableResult
    func markQuitting(timeout: Duration = .milliseconds(500)) async -> Bool {
        if marker.quitting != true {
            marker.quitting = true
            writeMarker()
        }
        let written = await file.written(lastTicket, timeout: timeout)
        if !written { logger.error("run marker quit write missed its \(timeout, privacy: .public) deadline") }
        return written
    }

    /// Returns once every write asked for so far is on disk (tests), or false after `timeout`.
    func flush(timeout: Duration = .seconds(5)) async -> Bool {
        await file.written(lastTicket, timeout: timeout)
    }

    /// A normal quit: the next launch is clean.
    func markCleanExit() {
        survival?.cancel()
        let descriptor = fatalSignalDescriptor
        fatalSignalDescriptor = -1
        if descriptor >= 0 { close(descriptor) }
        // First: it waits for the writer's queue, which runs the launch's takeover that names the exception file.
        file.close()
        UncaughtExceptionRecorder.uninstall()
        // SAFETY: unlink reads the NUL-terminated copy of the path Swift makes for the call.
        unsafe unlink(exceptionFile.path)
    }

    /// Hands the marker (about 200 bytes) to the background writer, which encodes it there (``encode(_:)``).
    private func writeMarker() {
        let (run, logger) = (marker, logger)
        lastTicket = file.submit(encoding: {
            do { return try AppRunMarker.encode(run) } catch {
                logger.error("run marker encode failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        })
    }

    /// The crash keys a run's crash path wrote (`url`: its `run.crashkeys`); nil when that run ended with no crash
    /// path (a normal quit, SIGKILL, power loss). Off the main thread.
    nonisolated static func readCrashKeys(_ url: URL) -> CrashKeys? {
        (try? String(blockingContentsOf: url, encoding: .utf8)).flatMap { CrashKeys(record: $0) }
    }

    /// The previous run's marker in these files. Blocking: the launch read's body (``prepareLaunch(directory:now:bootSession:)``).
    nonisolated static func readPrevious(marker: URL, signal: URL, exception: URL? = nil) -> PreviousRun? {
        // concurrency-allow: on the files lane once at launch, a file of about 150 bytes in Application Support.
        guard let data = try? Data(contentsOf: marker) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var run = try? decoder.blockingDecode(PreviousRun.self, from: data) else { return nil }
        // concurrency-allow: on the files lane once at launch, a file of at most 3 bytes.
        if let text = try? String(contentsOf: signal, encoding: .utf8),
           let first = text.split(whereSeparator: \.isNewline).first,
           let number = Int32(first.trimmingCharacters(in: .whitespaces)), number > 0 {
            run.signal = number
        }
        if let exception { run.exception = UncaughtExceptionRecorder.read(exception) }
        return run
    }
}

extension PreviousRun {
    /// How this run ended, seen from a launch in boot `current`; nil when it quit as asked. A handler's record
    /// is a crash whatever the boot: the fault ended the run before any restart did. No handler and another
    /// boot is a system shutdown (power loss, a kernel panic, a forced restart); no handler in this boot is a
    /// kill (`kill -9`, jetsam, Force Quit).
    ///
    /// Chrome's model: the clean-exit beacon (components/metrics/clean_exit_beacon.cc) says only that a run did
    /// not end cleanly; an unclean exit while the system session ended is counted apart
    /// (components/metrics/stability_metrics_provider.cc). Here the session is `kern.bootsessionuuid`.
    nonisolated func uncleanExit(bootSession current: String?) -> HistogramID.UncleanExit? {
        if endedAsAsked { return nil }
        if crashed { return .crash }
        if let bootSession, let current, bootSession != current { return .systemShutdown }
        return .killed
    }

    /// The run `LaunchRecovery` decides on from boot `current`: none when the machine's restart ended it, which
    /// is neither a crash nor a restart loop.
    nonisolated func forRecovery(bootSession current: String?) -> PreviousRun? {
        uncleanExit(bootSession: current) == .systemShutdown ? nil : self
    }

    /// The launch caches' safe mode after this run, seen from a launch in boot `current`.
    nonisolated func safeMode(bootSession current: String?) -> LaunchSafeMode {
        LaunchSafeMode.after(startupComplete: startupComplete, incompleteLaunches: incompleteLaunches, endedAsAsked: endedAsAsked,
                             machineRestarted: uncleanExit(bootSession: current) == .systemShutdown)
    }

    /// The run, seen from boot `current`, when it ended with no handler of its own and not as asked (killed, or
    /// the Mac shut down), so no crash report covers its end; nil after a quit or a crash.
    nonisolated func unreported(bootSession current: String?) -> PreviousRun? {
        let exit = uncleanExit(bootSession: current)
        return exit == nil || exit == .crash ? nil : self
    }
}

extension AppRunMarker {
    /// Starts the marker's launch read in `sequence` (`main` posts it before the settings read in that sequence, so
    /// it has ended when `AppServices` is made): reads the previous run's files and opens this run's `run.signal` and
    /// `run.crashkeys` under spare names, on the files lane. It changes none of the previous run's files.
    ///
    /// - Parameters:
    ///   - directory: The marker folder (``standardDirectory(bundleID:)``; tests pass their own).
    ///   - sequence: The launch's files-lane sequence.
    ///   - now: This run's launch time, stored in its marker.
    ///   - bootSession: This boot's id; default ``currentBootSession()``, asked on the lane.
    ///   - gate: The launch caches' decision, which the read asks (``launchSafeMode(directory:now:bootSession:processStart:)``
    ///     decides it when no cache read did first); nil decides it for this read only (tests).
    /// - Returns: The read; its value is what ``init(launch:)`` takes.
    nonisolated static func startLaunchRead(directory: URL, in sequence: WorkSequence, now: Date = Date(),
                                            bootSession: @escaping @Sendable () -> String? = { AppRunMarker.currentBootSession() },
                                            gate: LaunchSafeMode.Gate? = nil)
        -> LaunchRead<Launch> {
        // A read quit drops before it ran: no previous run and no files, so no handlers.
        let dropped = Launch(directory: directory, bootSession: nil, previous: nil, previousCrashKeys: nil,
                             marker: PreviousRun(pid: getpid(), launched: now, recovery: false, survived: false, signal: nil),
                             failure: "the launch read was dropped at quit", signalDescriptor: -1, keysDescriptor: -1)
        return LaunchRead(in: sequence, dropped: dropped) {
            prepareLaunch(directory: directory, now: now, bootSession: bootSession(), gate: gate)
        }
    }

    /// The launch read's body: blocking, on the files lane. It reads the previous run's files and leaves them as they
    /// are; the only files it writes are this run's spare ones. `processStart` is this process's kernel start, stored
    /// in its marker so the next launch takes only this process's black box and crash-key page.
    /// `gate` is the launch caches' decision (``startLaunchRead(directory:in:now:bootSession:gate:)``).
    nonisolated static func prepareLaunch(directory: URL, now: Date, bootSession: String?,
                                          processStart: UInt64? = AppRunMarker.currentProcessStart(),
                                          gate: LaunchSafeMode.Gate? = nil) -> Launch {
        let markerURL = directory.appending(path: "run.json"), signalURL = directory.appending(path: "run.signal")
        // Before this run's files are opened: the decision reads the previous run's marker and writes `run.launch`.
        let safeMode = (gate ?? LaunchSafeMode.Gate(decide: {
            AppRunMarker.launchSafeMode(directory: directory, now: now, bootSession: bootSession, processStart: processStart)
        })).safeMode
        let previous = readPrevious(marker: markerURL, signal: signalURL, exception: directory.appending(path: "run.exception"))
        let previousKeys = readCrashKeys(directory.appending(path: "run.crashkeys"))
        let marker = PreviousRun(pid: getpid(), launched: now,
                                 recovery: LaunchRecovery.watchesForLoop(previous: previous?.forRecovery(bootSession: bootSession)),
                                 survived: false, signal: nil, bootSession: bootSession, processStart: processStart,
                                 startupComplete: false, incompleteLaunches: safeMode.incompleteLaunches)
        func launch(failure: String?, signal: Int32 = -1, keys: Int32 = -1) -> Launch {
            Launch(directory: directory, bootSession: bootSession, previous: previous, previousCrashKeys: previousKeys,
                   marker: marker, failure: failure, signalDescriptor: signal, keysDescriptor: keys, safeMode: safeMode)
        }
        do { try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            return launch(failure: String(describing: error))
        }
        let files = openRunFiles(in: directory)
        return launch(failure: nil, signal: files.signal, keys: files.keys)
    }

    /// The file of a launch's first record (`LaunchSafeMode.Beacon`), beside `run.json`.
    nonisolated static let beaconName = "run.launch"

    /// The launch caches' crash-streak decision for this launch, the launch's ``LaunchSafeMode/Gate``'s `decide`:
    /// from the previous run's `run.json`, or from the last launch's `run.launch` when that launch
    /// ended before its marker was written (a cache read that ended it is counted so); then this launch's
    /// `run.launch`, written before it returns. A second call finds that record and gives the same answer. Blocking:
    /// on a launch lane, before any launch cache is read.
    nonisolated static func launchSafeMode(directory: URL, now: Date = Date(), bootSession: String? = AppRunMarker.currentBootSession(),
                                           processStart: UInt64? = AppRunMarker.currentProcessStart()) -> LaunchSafeMode {
        let beaconURL = directory.appending(path: beaconName), pid = getpid()
        let last = LaunchSafeMode.Beacon.read(beaconURL)
        if let last, last.isProcess(pid: pid, processStart: processStart) { return LaunchSafeMode(incompleteLaunches: last.incompleteLaunches) }
        let previous = readPrevious(marker: directory.appending(path: "run.json"), signal: directory.appending(path: "run.signal"))
        let safeMode: LaunchSafeMode
        // The last launch left a record but no marker of its own (it ended before the marker was made).
        if let last, previous.map({ !last.isProcess(pid: $0.pid, processStart: $0.processStart) && last.launched > $0.launched }) ?? true {
            safeMode = last.ended(bootSession: bootSession)
        } else {
            safeMode = previous?.safeMode(bootSession: bootSession) ?? .noStreak
        }
        let beacon = LaunchSafeMode.Beacon(pid: pid, processStart: processStart, launched: now, bootSession: bootSession,
                                           incompleteLaunches: safeMode.incompleteLaunches)
        do {
            try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
            try beacon.store(at: beaconURL)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash").error("launch record not written: \(String(describing: error), privacy: .public)")
        }
        return safeMode
    }

    /// The names this run's `run.signal` and `run.crashkeys` are open under until the marker is made.
    nonisolated static let spareSignalName = "run.signal.next", spareCrashKeysName = "run.crashkeys.next"

    /// Opens this run's `run.signal` and `run.crashkeys` empty under their spare names (emptying any a launch that
    /// ended before its marker left). Returns -1 for a file that did not open; no keys file without a signal file.
    private nonisolated static func openRunFiles(in directory: URL) -> (signal: Int32, keys: Int32) {
        let signalPath = directory.appending(path: spareSignalName).path, keysPath = directory.appending(path: spareCrashKeysName).path
        return blockingCall(.fileIO) { () -> (signal: Int32, keys: Int32) in
            // SAFETY: open reads the NUL-terminated copy of each path Swift makes for the call.
            let signal = unsafe open(signalPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            return signal < 0 ? (-1, -1) : (signal, unsafe open(keysPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600))
        }
    }

    /// Replaces the previous run's crash record with this run's open files: removes its `run.exception` and renames
    /// the spare files (``openRunFiles(in:)``) over its `run.signal` and `run.crashkeys`; for a file that did not open,
    /// it removes the previous run's (that record is not this run's). Blocking: on the marker writer's queue, before
    /// this run's first `run.json` (``init(launch:)``).
    nonisolated static func takeOverCrashFiles(of launch: Launch) {
        let path = { (name: String) in launch.directory.appending(path: name).path }
        let files = [(path(spareSignalName), path("run.signal"), launch.signalDescriptor >= 0),
                     (path(spareCrashKeysName), path("run.crashkeys"), launch.keysDescriptor >= 0)]
        // The aside file is where launches before the launch read moved the previous run's keys.
        let removed = [path("run.exception"), path("run.crashkeys.previous")]
        blockingCall(.fileIO) {
            for (spare, target, opened) in files {
                // SAFETY: rename and unlink read the NUL-terminated copies of the paths Swift makes for each call.
                if unsafe !opened || rename(spare, target) != 0 { unsafe unlink(target) }
            }
            // SAFETY: unlink reads the NUL-terminated copy of the path Swift makes for the call.
            for file in removed { unsafe unlink(file) }
        }
    }

    /// `run.json`'s bytes for `marker` (about 120).
    nonisolated static func encode(_ marker: PreviousRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(marker)
    }
}
