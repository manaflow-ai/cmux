import CmuxNextCompat
import CmuxNextCrashReporting
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

/// Marks this run as live, so the next launch can tell a crash from a
/// normal quit (`LaunchRecovery`). Per bundle id, so tagged builds never
/// read each other's marker.
///
/// - `run.json`: pid, launch time, whether this run is a restart, whether
///   it lived past the quick-crash window, and whether a requested quit had
///   begun (`markQuitting`); whether its startup completed, the last startup
///   task it began before that, and the runs in a row before it that ended
///   before theirs (`LaunchSafeMode`, ``observe(_:)``).
/// - `run.signal`: empty until a fatal signal handler writes its number.
///
/// A normal quit removes both. A quit that had begun, or a requested-quit
/// signal (`LaunchRecovery.requestedQuitSignals`), counts as a quit that
/// was asked for, even when the process is then killed before it ends.
///
/// `run.json` is encoded and written off the main thread (`RunMarkerFile`);
/// the quit path awaits its `quitting` write (`markQuitting`). Made in the
/// app's `main` before any launch cache is read, so a cache that ends the
/// launch is counted, and skipped after a streak (``safeMode``).
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
    /// Whether this launch reads the launch caches: not after a streak of runs that ended before their startup
    /// completed (p08-startup-089).
    nonisolated let safeMode: LaunchSafeMode
    private var signalFile: URL { directory.appending(path: "run.signal") }
    private var exceptionFile: URL { directory.appending(path: "run.exception") }
    private var crashKeysFile: URL { directory.appending(path: "run.crashkeys") }
    /// The previous run's `run.crashkeys`, moved aside at launch so this run's crash path gets an empty file;
    /// read off the main thread (``readCrashKeys(_:)``).
    var previousCrashKeysFile: URL { directory.appending(path: "run.crashkeys.previous") }

    /// The app's marker folder for `bundleID`.
    static func standardDirectory(bundleID: String?) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux-next", directoryHint: .isDirectory)
            .appending(path: CrashReportWriter.safe(bundleID ?? "unknown"), directoryHint: .isDirectory)
    }

    /// Reads the previous run's marker in `directory`, then marks this run
    /// live and installs the fatal signal handlers. `bootSession` is this
    /// boot's id, stored in the marker (tests pass their own).
    init(directory root: URL, now: Date = Date(), bootSession: String? = AppRunMarker.currentBootSession()) {
        self.directory = root
        file = RunMarkerFile(url: root.appending(path: "run.json"), signalURL: root.appending(path: "run.signal"))
        let previous = Self.readPrevious(marker: root.appending(path: "run.json"), signal: root.appending(path: "run.signal"),
                                         exception: root.appending(path: "run.exception"))
        previousExit = previous?.uncleanExit(bootSession: bootSession)
        let recovered = previous?.forRecovery(bootSession: bootSession)
        recovery = LaunchRecovery.decide(previous: recovered)
        let safeMode = previous?.safeMode(bootSession: bootSession) ?? .noStreak
        self.safeMode = safeMode
        marker = PreviousRun(pid: getpid(), launched: now, recovery: LaunchRecovery.watchesForLoop(previous: recovered),
                             survived: false, signal: nil, bootSession: bootSession, startupComplete: false,
                             incompleteLaunches: safeMode.incompleteLaunches)
        start()
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

    private func start() {
        // First, before any crash handler is installed (the uncaught-exception recorder below, the crash deadline,
        // the fatal-signal handlers) and whether or not the files below open: the crash keys' block, which those
        // handlers read (CrashKeys).
        CrashReporter.prepareCrashKeysBlock()
        do {
            // concurrency-allow: once at launch; a stat when the folder exists (every launch after the first).
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("run marker folder failed: \(String(describing: error), privacy: .public)")
            return
        }
        writeMarker()
        // The previous run's exception was read in init; this run records its own.
        // SAFETY: unlink reads the NUL-terminated copy of the path Swift makes for the call.
        unsafe unlink(exceptionFile.path)
        UncaughtExceptionRecorder.install(writingTo: exceptionFile)
        // concurrency-allow: once at launch; truncates a file of at most 3 bytes, no fsync.
        // SAFETY: open reads the NUL-terminated copy of the path Swift makes for the call.
        let descriptor = unsafe open(signalFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        fatalSignalDescriptor = descriptor
        // The crash path writes this run's crash keys here (CrashKeys); the previous run's move aside, to be read
        // off the main thread (CrashRecoveryService). No previous file: an older one aside is not this launch's.
        // concurrency-allow: once at launch, as run.signal's open above; a rename in one folder, no fsync.
        // blocking-allow: the crash path needs this run's file open before the handlers are installed, at launch
        // on main like run.signal's open above; no seam runs earlier.
        // SAFETY: rename, unlink and open read the NUL-terminated copies of the paths Swift makes for each call.
        if unsafe rename(crashKeysFile.path, previousCrashKeysFile.path) != 0 { unsafe unlink(previousCrashKeysFile.path) }
        // concurrency-allow: once at launch, as run.signal's open above; creates an empty file, no fsync.
        // blocking-allow: as the rename above (the descriptor the crash path writes to, before its handlers).
        let keysDescriptor = unsafe open(crashKeysFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if keysDescriptor >= 0 { CrashReporter.prepareCrashKeysRecord(descriptor: keysDescriptor) }
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

    /// Installs the fatal signal handlers. Call again after CefInitialize:
    /// Chromium resets these signals to their default action at start.
    /// They run on the faulting thread's alternate signal stack, so a stack
    /// overflow is recorded too: the main thread's, and one on every thread
    /// started after the first call.
    func installHandlers() {
        guard fatalSignalDescriptor >= 0 else { return }
        CrashReporter.installAlternateSignalStacks()
        // SIGTERM, SIGINT and SIGHUP are requested quits: `QuitSignal` turns
        // them into "Quit, keep sessions" once installed; until then this
        // handler records them.
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

    /// A requested quit has begun (`QuitCoordinator`): the next launch is
    /// clean even if this process is killed before the quit finishes, for
    /// example by dev tooling's SIGKILL after its bounded wait while
    /// Chromium shuts down. Returns once `quitting` is on disk, or false
    /// after `timeout` (the quit goes on either way).
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

    /// Returns once every write asked for so far is on disk (tests), or
    /// false after `timeout`.
    func flush(timeout: Duration = .seconds(5)) async -> Bool {
        await file.written(lastTicket, timeout: timeout)
    }

    /// A normal quit: the next launch is clean.
    func markCleanExit() {
        survival?.cancel()
        let descriptor = fatalSignalDescriptor
        fatalSignalDescriptor = -1
        if descriptor >= 0 { close(descriptor) }
        UncaughtExceptionRecorder.uninstall()
        // SAFETY: unlink reads the NUL-terminated copy of the path Swift makes for the call.
        unsafe unlink(exceptionFile.path)
        file.close()
    }

    /// Hands the marker (about 200 bytes) to the background writer, which encodes it there.
    private func writeMarker() {
        let (run, logger) = (marker, logger)
        lastTicket = file.submit(encoding: {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            do { return try encoder.encode(run) } catch {
                logger.error("run marker encode failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        })
    }

    /// The crash keys a run's crash path wrote (`url`: ``previousCrashKeysFile``); nil when that run ended with no
    /// crash path (a normal quit, SIGKILL, power loss). Off the main thread.
    nonisolated static func readCrashKeys(_ url: URL) -> CrashKeys? {
        (try? String(blockingContentsOf: url, encoding: .utf8)).flatMap { CrashKeys(record: $0) }
    }

    nonisolated static func readPrevious(marker: URL, signal: URL, exception: URL? = nil) -> PreviousRun? {
        // concurrency-allow: once at launch before the first window, a file of about 150 bytes in Application Support.
        guard let data = try? Data(contentsOf: marker) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var run = try? decoder.blockingDecode(PreviousRun.self, from: data) else { return nil }
        // concurrency-allow: once at launch before the first window, a file of at most 3 bytes.
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

    /// The launch caches' safe mode after this run, seen from a launch in boot `current` (p08-startup-089).
    nonisolated func safeMode(bootSession current: String?) -> LaunchSafeMode {
        LaunchSafeMode.after(startupComplete: startupComplete, incompleteLaunches: incompleteLaunches, endedAsAsked: endedAsAsked,
                             machineRestarted: uncleanExit(bootSession: current) == .systemShutdown)
    }
}
