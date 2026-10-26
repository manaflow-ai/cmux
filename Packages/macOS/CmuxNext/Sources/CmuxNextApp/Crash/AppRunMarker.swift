import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextTrace
import CmuxNextWakeups
import Darwin
import Foundation
import os

/// Descriptor the fatal-signal handler writes the signal number into.
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
        _ = withUnsafeBytes(of: &bytes) { Darwin.write(descriptor, $0.baseAddress, 3) }
    }
    // After run.signal: a fault in here re-runs under SIG_DFL and still leaves the signal recorded.
    CrashReporter.recordCrashKeys()
    _ = Darwin.signal(signal, SIG_DFL)
    let sentBySoftware = info.map { $0.pointee.si_code == SI_USER || $0.pointee.si_code == SI_QUEUE } ?? true
        || arrivedOnASystemCall(context)
    let fault = signal == SIGSEGV || signal == SIGBUS || signal == SIGILL || signal == SIGFPE || signal == SIGTRAP || signal == SIGSYS
    if sentBySoftware || !fault { _ = raise(signal) }
}

/// Whether the thread was returning from `svc #0x80`: syndrome class 0x15 and that word before the pc.
/// Sentry's re-raise arrives on the `sigreturn` to the faulting pc, which may be unmapped, so the
/// word is read with `vm_read_overwrite` and a failed read is a fault. No context re-raises.
nonisolated func arrivedOnASystemCall(_ context: UnsafeMutableRawPointer?) -> Bool {
    #if arch(arm64)
    guard let state = context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext else { return true }
    guard state.pointee.__es.__esr >> 26 == 0x15 else { return false }
    let pc = UInt(state.pointee.__ss.__pc)
    guard pc >= 4 else { return false }
    var word: UInt32 = 0, read: vm_size_t = 0
    let result = withUnsafeMutablePointer(to: &word) { vm_read_overwrite(mach_task_self_, vm_address_t(pc - 4), 4, vm_address_t(UInt(bitPattern: $0)), &read) }
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
///   begun (`markQuitting`).
/// - `run.signal`: empty until a fatal signal handler writes its number.
///
/// A normal quit removes both. A quit that had begun, or a requested-quit
/// signal (`LaunchRecovery.requestedQuitSignals`), counts as a quit that
/// was asked for, even when the process is then killed before it ends.
///
/// `run.json` is written off the main thread (`RunMarkerFile`); the quit
/// path awaits its `quitting` write (`markQuitting`).
@MainActor
final class AppRunMarker {
    private let directory: URL
    private let file: RunMarkerFile
    private var marker: PreviousRun
    /// The ticket of the newest submitted write.
    private var lastTicket: UInt64 = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    private var survivalTask: Task<Void, Never>?

    /// How this launch follows the previous run.
    let recovery: LaunchRecovery
    /// How the previous run ended when it did not quit as asked (stability.unclean_exit, task 109); nil after a
    /// normal or requested quit, or on a first launch.
    let previousExit: UncleanExit?
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
        marker = PreviousRun(pid: getpid(), launched: now, recovery: LaunchRecovery.watchesForLoop(previous: recovered),
                             survived: false, signal: nil, bootSession: bootSession)
        start()
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
        unlink(exceptionFile.path)
        UncaughtExceptionRecorder.install(writingTo: exceptionFile)
        // concurrency-allow: once at launch; truncates a file of at most 3 bytes, no fsync.
        let descriptor = open(signalFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        fatalSignalDescriptor = descriptor
        // The crash path writes this run's crash keys here (CrashKeys); the previous run's move aside, to be read
        // off the main thread (CrashRecoveryService). No previous file: an older one aside is not this launch's.
        // concurrency-allow: once at launch, as run.signal's open above; a rename in one folder, no fsync.
        // blocking-allow: the crash path needs this run's file open before the handlers are installed, at launch
        // on main like run.signal's open above; no seam runs earlier.
        if rename(crashKeysFile.path, previousCrashKeysFile.path) != 0 { unlink(previousCrashKeysFile.path) }
        // concurrency-allow: once at launch, as run.signal's open above; creates an empty file, no fsync.
        // blocking-allow: as the rename above (the descriptor the crash path writes to, before its handlers).
        let keysDescriptor = open(crashKeysFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if keysDescriptor >= 0 { CrashReporter.prepareCrashKeysRecord(descriptor: keysDescriptor) }
        CrashReporter.installCrashDeadline()
        CrashReporter.installCrashWatcher(sampleFile: directory.appending(path: "crash-watcher-sample.txt").path)
        installHandlers()
        let window = LaunchRecovery.quickCrashWindow
        survivalTask = Task { [weak self] in
            // wakeup-allow: deadline the quick-crash window after launch; fires once, cancelled by a clean exit. It is
            // armed inside AppServices.init, before the app's MainDeadlineScheduler can be read.
            do { try await Task.sleep(for: window, tolerance: WakeLeeway.window(delay: window).tolerance) } catch { return }
            self?.markSurvived()
        }
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
            action.__sigaction_u.__sa_sigaction = fatalSignalHandler
            action.sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
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
        survivalTask?.cancel()
        let descriptor = fatalSignalDescriptor
        fatalSignalDescriptor = -1
        if descriptor >= 0 { close(descriptor) }
        UncaughtExceptionRecorder.uninstall()
        unlink(exceptionFile.path)
        file.close()
    }

    /// Encodes the marker (about 120 bytes) and hands it to the background
    /// writer.
    private func writeMarker() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do { lastTicket = file.submit(try encoder.encode(marker)) } catch {
            logger.error("run marker encode failed: \(String(describing: error), privacy: .public)")
        }
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

/// How a run that did not quit as asked ended (stability.unclean_exit, task 109).
///
/// Chrome's model: the clean-exit beacon (components/metrics/clean_exit_beacon.cc) says only that a run did not
/// end cleanly; crashes come from the crash reporter, and an unclean exit while the system session ended is
/// counted apart (components/metrics/stability_metrics_provider.cc). Here the run's handler record is the crash
/// report and `kern.bootsessionuuid` is the session.
nonisolated enum UncleanExit: String, Sendable, Equatable {
    /// The run's fatal-signal handler or uncaught-exception recorder ran.
    case crash
    /// No handler ran and the machine restarted since (power loss, a kernel panic, a forced restart).
    case systemShutdown = "system_shutdown"
    /// No handler ran in this boot: `kill -9`, jetsam, Force Quit.
    case killed
}

extension PreviousRun {
    /// How this run ended, seen from a launch in boot `current`; nil when it quit as asked. A handler's record
    /// is a crash whatever the boot: the fault ended the run before any restart did.
    nonisolated func uncleanExit(bootSession current: String?) -> UncleanExit? {
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
}
