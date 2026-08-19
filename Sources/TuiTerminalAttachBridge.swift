import CmuxSettings
import Darwin
import Foundation

/// I/O side of the cmux-tui terminal-backend spike: ensures the per-app-tag
/// daemon session is running, provisions daemon terminals for new surfaces,
/// and answers reattach queries during session restore. Decision logic lives
/// in `TuiTerminalAttachPolicy`.
///
/// SPIKE ONLY. This bridge blocks the main actor on short, bounded CLI calls
/// (daemon cold start up to ~5s, warm calls ~100ms) and uses a bounded
/// socket poll after spawning the daemon. The shipped design replaces all of
/// this with a launchd-supervised daemon and a native protocol client; the
/// deletion criterion is recorded in the migration plan.
@MainActor
final class TuiTerminalAttachBridge {
    static let shared = TuiTerminalAttachBridge()

    struct ProvisionedTerminal {
        let terminalID: String
        let attachCommand: String
    }

    /// Synchronous read of the beta flag for spawn/restore paths outside the
    /// SwiftUI update cycle, mirroring `RemoteTmuxController.isEnabled`.
    nonisolated static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.tuiTerminalBackend
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    private nonisolated static var binaryPath: String {
        let key = SettingCatalog().betaFeatures.tuiTerminalBackendBinaryPath
        let stored = String.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? key.defaultValue : trimmed
    }

    private var cachedTerminalIDs: (ids: Set<String>, fetchedAt: Date)?

    private var sessionName: String {
        TuiTerminalAttachPolicy.sessionName(
            controlSocketPath: TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.socketPath()
            )
        )
    }

    private var daemonSocketPath: String {
        TuiTerminalAttachPolicy.daemonSocketPath(
            sessionName: sessionName,
            temporaryDirectory: NSTemporaryDirectory(),
            uid: getuid()
        )
    }

    /// Creates one daemon-backed terminal for a brand-new surface. Returns
    /// nil on any failure (missing binary, daemon won't start, CLI error) so
    /// the caller falls back to today's fresh local spawn.
    func provisionTerminalForNewSurface() -> ProvisionedTerminal? {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            logSpike("provision.skip binary-not-executable path=\(binary)")
            return nil
        }
        guard ensureDaemonRunning(binary: binary) else { return nil }
        let session = sessionName
        guard let output = runCLI(
            binary: binary,
            arguments: ["--session", session, "--json", "workspace", "create", "--name", "cmux-gui"],
            timeout: 10
        ) else {
            logSpike("provision.fail workspace-create session=\(session)")
            return nil
        }
        guard let terminalID = TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: output) else {
            logSpike("provision.fail parse session=\(session)")
            return nil
        }
        cachedTerminalIDs = nil
        logSpike("provision.ok terminal=\(terminalID) session=\(session)")
        return ProvisionedTerminal(
            terminalID: terminalID,
            attachCommand: TuiTerminalAttachPolicy.attachCommand(
                binaryPath: binary,
                sessionName: session,
                terminalID: terminalID
            )
        )
    }

    /// Restore-side decision: reattach to a persisted daemon terminal, or
    /// fall back to a fresh spawn. Never starts the daemon: if it is not
    /// already running, the terminal it owned is gone anyway.
    func restoreDecision(
        snapshotTerminalID: String?,
        isRemoteTerminal: Bool,
        hasRemotePTYSessionID: Bool
    ) -> TuiTerminalAttachPolicy.RestoreDecision {
        guard Self.isEnabled, let snapshotTerminalID, !snapshotTerminalID.isEmpty else {
            return .freshSpawn
        }
        let daemonSocketAlive = Self.unixSocketAccepts(path: daemonSocketPath)
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: Self.isEnabled,
            snapshotTerminalID: snapshotTerminalID,
            isRemoteTerminal: isRemoteTerminal,
            hasRemotePTYSessionID: hasRemotePTYSessionID,
            daemonSocketAlive: daemonSocketAlive,
            daemonTerminalIDs: daemonSocketAlive ? liveTerminalIDs() : nil
        )
        logSpike("restore.decision terminal=\(snapshotTerminalID) alive=\(daemonSocketAlive) decision=\(decision)")
        return decision
    }

    /// The attach command for a terminal id this bridge (or a previous app
    /// run) provisioned.
    func attachCommand(terminalID: String) -> String {
        TuiTerminalAttachPolicy.attachCommand(
            binaryPath: Self.binaryPath,
            sessionName: sessionName,
            terminalID: terminalID
        )
    }

    // MARK: - Daemon lifecycle

    private func ensureDaemonRunning(binary: String) -> Bool {
        let socketPath = daemonSocketPath
        if Self.unixSocketAccepts(path: socketPath) { return true }
        let session = sessionName
        logSpike("daemon.start session=\(session)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["server", "start", "--session", session, "--headless"]
        let logPath = "/tmp/cmux-tui-\(session).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: logPath) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logSpike("daemon.start.fail error=\(error)")
            return false
        }
        // SPIKE: bounded poll for the daemon socket (max 5s). The principled
        // replacement is launchd supervision plus socket activation; this
        // bridge is scheduled for deletion before that ships.
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if Self.unixSocketAccepts(path: socketPath) { return true }
            if !process.isRunning {
                logSpike("daemon.start.exited status=\(process.terminationStatus)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        logSpike("daemon.start.timeout session=\(session)")
        return false
    }

    private func liveTerminalIDs() -> Set<String>? {
        if let cached = cachedTerminalIDs, Date().timeIntervalSince(cached.fetchedAt) < 3 {
            return cached.ids
        }
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        guard let output = runCLI(
            binary: binary,
            arguments: ["--session", sessionName, "--json", "terminal", "list"],
            timeout: 10
        ) else { return nil }
        guard let ids = TuiTerminalAttachPolicy.terminalIDs(fromTerminalListJSON: output) else {
            return nil
        }
        cachedTerminalIDs = (ids, Date())
        return ids
    }

    // MARK: - Helpers

    /// Runs one short cmux-tui CLI call, returning stdout. Bounded by
    /// `timeout` via a termination-handler semaphore; the process is killed
    /// on timeout.
    private nonisolated func runCLI(binary: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain stdout off-thread so a wedged CLI cannot block this call past
        // the timeout; EOF (and the drain) arrives once the process exits.
        let outputBox = TuiCLIOutputBox()
        let drained = DispatchSemaphore(value: 0)
        let readHandle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.store(readHandle.readDataToEndOfFile())
            drained.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard drained.wait(timeout: .now() + 2) == .success else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return outputBox.take()
    }

    /// True when a Unix socket at `path` accepts a connection.
    private nonisolated static func unixSocketAccepts(path: String) -> Bool {
        guard path.utf8.count < 104 else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { buffer -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < buffer.count else { return false }
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
            return true
        }
        guard copied else { return false }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, length)
            }
        }
        return result == 0
    }

    private nonisolated func logSpike(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog("tuiAttachSpike.\(message())")
#endif
    }
}

/// Lock-guarded byte buffer for the off-thread CLI stdout drain.
private final class TuiCLIOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ new: Data) {
        lock.lock()
        data = new
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
