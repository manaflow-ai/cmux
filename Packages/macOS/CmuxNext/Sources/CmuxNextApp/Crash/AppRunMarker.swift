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
private let fatalSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, _ in
    var bytes: (UInt8, UInt8, UInt8) = (UInt8(48 + (signal / 10) % 10), UInt8(48 + signal % 10), 10)
    let descriptor = fatalSignalDescriptor
    if descriptor >= 0 {
        // Only the first signal is recorded (abort() may follow a raise).
        fatalSignalDescriptor = -1
        // concurrency-allow: signal handler context (the process is ending), one 3-byte write to a local file.
        _ = withUnsafeBytes(of: &bytes) { Darwin.write(descriptor, $0.baseAddress, 3) }
    }
    _ = Darwin.signal(signal, SIG_DFL)
    let sentBySoftware = info.map { $0.pointee.si_code == SI_USER || $0.pointee.si_code == SI_QUEUE } ?? true
    let fault = signal == SIGSEGV || signal == SIGBUS || signal == SIGILL || signal == SIGFPE || signal == SIGTRAP || signal == SIGSYS
    if sentBySoftware || !fault { _ = raise(signal) }
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

    private var signalFile: URL { directory.appending(path: "run.signal") }

    /// The app's marker folder for `bundleID`.
    static func standardDirectory(bundleID: String?) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux-next", directoryHint: .isDirectory)
            .appending(path: CrashReportWriter.safe(bundleID ?? "unknown"), directoryHint: .isDirectory)
    }

    /// Reads the previous run's marker in `directory`, then marks this run
    /// live and installs the fatal signal handlers.
    init(directory root: URL, now: Date = Date()) {
        self.directory = root
        file = RunMarkerFile(url: root.appending(path: "run.json"), signalURL: root.appending(path: "run.signal"))
        let previous = Self.readPrevious(marker: root.appending(path: "run.json"), signal: root.appending(path: "run.signal"))
        recovery = LaunchRecovery.decide(previous: previous)
        marker = PreviousRun(pid: getpid(), launched: now, recovery: recovery.isRestart, survived: false, signal: nil)
        start()
    }

    private func start() {
        do {
            // concurrency-allow: once at launch; a stat when the folder exists (every launch after the first).
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("run marker folder failed: \(String(describing: error), privacy: .public)")
            return
        }
        writeMarker()
        // concurrency-allow: once at launch; truncates a file of at most 3 bytes, no fsync.
        let descriptor = open(signalFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        fatalSignalDescriptor = descriptor
        installHandlers()
        let window = LaunchRecovery.quickCrashWindow
        survivalTask = Task { [weak self] in
            // wakeup-allow: one-shot quick-crash window after launch; fires once
            do { try await Task.sleep(for: window) } catch { return }
            self?.markSurvived()
        }
    }

    /// Installs the fatal signal handlers. Call again after CefInitialize:
    /// Chromium resets these signals to their default action at start.
    func installHandlers() {
        guard fatalSignalDescriptor >= 0 else { return }
        // SIGTERM, SIGINT and SIGHUP are requested quits: `QuitSignal` turns
        // them into "Quit, keep sessions" once installed; until then this
        // handler records them.
        let fatal = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS]
        let signals = QuitSignal.isInstalled ? fatal : fatal + LaunchRecovery.requestedQuitSignals.sorted()
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = fatalSignalHandler
            action.sa_flags = SA_RESETHAND | SA_SIGINFO
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

    nonisolated static func readPrevious(marker: URL, signal: URL) -> PreviousRun? {
        // concurrency-allow: once at launch before the first window, a file of about 150 bytes in Application Support.
        guard let data = try? Data(contentsOf: marker) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var run = try? decoder.decode(PreviousRun.self, from: data) else { return nil }
        // concurrency-allow: once at launch before the first window, a file of at most 3 bytes.
        if let text = try? String(contentsOf: signal, encoding: .utf8),
           let first = text.split(whereSeparator: \.isNewline).first,
           let number = Int32(first.trimmingCharacters(in: .whitespaces)), number > 0 {
            run.signal = number
        }
        return run
    }
}
