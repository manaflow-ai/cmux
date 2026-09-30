import Darwin
import Foundation
import os

/// Descriptor the fatal-signal handler writes the signal number into.
nonisolated(unsafe) private var fatalSignalDescriptor: Int32 = -1

/// Writes the signal number ("11\n") and re-raises it with the default
/// action, so macOS still writes its crash report. Async-signal-safe: one
/// write(2) of stack bytes, signal(3), raise(3).
private let fatalSignalHandler: @convention(c) (Int32) -> Void = { signal in
    var bytes: (UInt8, UInt8, UInt8) = (UInt8(48 + (signal / 10) % 10), UInt8(48 + signal % 10), 10)
    let descriptor = fatalSignalDescriptor
    if descriptor >= 0 {
        // concurrency-allow: signal handler context (the process is ending), one 3-byte write to a local file.
        _ = withUnsafeBytes(of: &bytes) { Darwin.write(descriptor, $0.baseAddress, 3) }
    }
    _ = Darwin.signal(signal, SIG_DFL)
    _ = raise(signal)
}

/// Marks this run as live, so the next launch can tell a crash from a
/// normal quit (`LaunchRecovery`). Per bundle id, so tagged builds never
/// read each other's marker.
///
/// - `run.json`: pid, launch time, whether this run is a restart, and
///   whether it lived past the quick-crash window.
/// - `run.signal`: empty until a fatal signal handler writes its number.
///
/// A normal quit removes both. SIGTERM counts as a quit that was asked for.
@MainActor
final class AppRunMarker {
    private let directory: URL
    private var marker: PreviousRun
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    private var survivalTask: Task<Void, Never>?

    /// How this launch follows the previous run.
    let recovery: LaunchRecovery

    private var markerFile: URL { directory.appending(path: "run.json") }
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
        let previous = Self.readPrevious(marker: root.appending(path: "run.json"), signal: root.appending(path: "run.signal"))
        recovery = LaunchRecovery.decide(previous: previous)
        marker = PreviousRun(pid: getpid(), launched: now, recovery: recovery.isRestart, survived: false, signal: nil)
        start()
    }

    private func start() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeMarker()
        } catch {
            logger.error("run marker write failed: \(String(describing: error), privacy: .public)")
            return
        }
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
        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS, SIGTERM] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = fatalSignalHandler
            action.sa_flags = SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    private func markSurvived() {
        marker.survived = true
        try? writeMarker()
    }

    /// A normal quit: the next launch is clean.
    func markCleanExit() {
        survivalTask?.cancel()
        let descriptor = fatalSignalDescriptor
        fatalSignalDescriptor = -1
        if descriptor >= 0 { close(descriptor) }
        try? FileManager.default.removeItem(at: markerFile)
        try? FileManager.default.removeItem(at: signalFile)
    }

    private func writeMarker() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(marker).write(to: markerFile, options: .atomic)
    }

    nonisolated static func readPrevious(marker: URL, signal: URL) -> PreviousRun? {
        // concurrency-allow: once at launch before the first window, a file of about 150 bytes in Application Support.
        guard let data = try? Data(contentsOf: marker) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var run = try? decoder.decode(PreviousRun.self, from: data) else { return nil }
        // concurrency-allow: once at launch before the first window, a file of at most 3 bytes.
        if let text = try? String(contentsOf: signal, encoding: .utf8),
           let number = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 {
            run.signal = number
        }
        return run
    }
}
