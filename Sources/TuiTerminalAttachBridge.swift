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

    /// Manual-IO data-path variant: the daemon terminal feeds a
    /// manual-mirror Ghostty surface through a `--pipe-io` relay instead of
    /// running the attach client as the surface command. Requires the main
    /// backend flag.
    nonisolated static var isManualIOEnabled: Bool {
        guard isEnabled else { return false }
        let key = SettingCatalog().betaFeatures.tuiTerminalBackendManualIO
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    /// A pump owning the `--pipe-io` relay for one daemon terminal, sharing
    /// this bridge's binary, per-app-tag session, and config isolation.
    func makeManualIOPump(terminalID: String) -> TuiManualIOPump {
        TuiManualIOPump(
            binaryPath: Self.binaryPath,
            sessionName: sessionName,
            terminalID: terminalID,
            environment: Self.bridgeEnvironment
        )
    }

    private nonisolated static var binaryPath: String {
        let key = SettingCatalog().betaFeatures.tuiTerminalBackendBinaryPath
        let stored = String.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? key.defaultValue : trimmed
    }

    private var cachedTerminalIDs: (ids: Set<String>, fetchedAt: Date)?
    private var cachedCloseConfirmations: [String: (required: Bool, fetchedAt: Date)] = [:]

    /// App-managed config for every bridge-spawned cmux-tui process (daemon,
    /// CLI calls, attach clients). Isolates app sessions from the user's
    /// interactive `~/.config/cmux/cmux-tui.json`, whose schema may belong to
    /// a different binary version; parse warnings from that file print onto
    /// the surface and flash when the alt screen pops on quit.
    nonisolated static let bridgeConfigPath: String = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("tui-bridge.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data("{}\n".utf8).write(to: file)
        }
        return file.path
    }()

    /// Environment for every bridge-spawned cmux-tui process (the daemon and
    /// each CLI call): the app process environment plus the config isolation
    /// override. Internal (not private) so tests can pin the isolation.
    nonisolated static var bridgeEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CMUX_TUI_CONFIG"] = bridgeConfigPath
        return env
    }

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
        guard let output = Self.runCLI(
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
                terminalID: terminalID,
                configPath: Self.bridgeConfigPath
            )
        )
    }

    /// The bridge daemon session backing this app instance, for callers that
    /// must recognize (and skip) it during discovery.
    var currentSessionName: String { sessionName }

    /// Harbor: creates one daemon terminal running `shellCommand` through the
    /// daemon's default login shell, inside a shared "harbor" daemon
    /// workspace (created on first use, found by name selector afterwards).
    /// Returns the terminal id, or nil on any failure so the caller can fall
    /// back or report. Same spike contract as `provisionTerminalForNewSurface`:
    /// short bounded CLI calls on the main actor.
    func provisionHarborTerminal(shellCommand: String, terminalName: String) -> String? {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            logSpike("harbor.provision.skip binary-not-executable path=\(binary)")
            return nil
        }
        guard ensureDaemonRunning(binary: binary) else { return nil }
        let session = sessionName

        func run(inWorkspace selector: String) -> String? {
            guard let output = Self.runCLI(
                binary: binary,
                arguments: TuiTerminalAttachPolicy.harborRunArguments(
                    sessionName: session,
                    workspaceSelector: selector,
                    terminalName: terminalName,
                    shellCommand: shellCommand
                ),
                timeout: 10
            ) else { return nil }
            return TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: output)
        }

        // Reuse the shared harbor workspace when it already exists; create it
        // only when the name selector fails to resolve.
        if let terminalID = run(inWorkspace: TuiTerminalAttachPolicy.harborWorkspaceName) {
            cachedTerminalIDs = nil
            logSpike("harbor.provision.ok terminal=\(terminalID) session=\(session)")
            return terminalID
        }
        guard let createOutput = Self.runCLI(
            binary: binary,
            arguments: TuiTerminalAttachPolicy.harborWorkspaceCreateArguments(sessionName: session),
            timeout: 10
        ), let workspaceID = TuiTerminalAttachPolicy.workspaceID(fromWorkspaceCreateJSON: createOutput) else {
            logSpike("harbor.provision.fail workspace-create session=\(session)")
            return nil
        }
        guard let terminalID = run(inWorkspace: workspaceID) else {
            logSpike("harbor.provision.fail run session=\(session)")
            return nil
        }
        cachedTerminalIDs = nil
        logSpike("harbor.provision.ok terminal=\(terminalID) session=\(session)")
        return terminalID
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

    /// Quit-time inventory: whether the daemon session for this app instance
    /// should be offered the keep-vs-stop choice. Cheap when the daemon is
    /// down (one socket connect); one short CLI call otherwise.
    func shouldPromptToKeepDaemonSessionsOnQuit(quitAlreadyConfirmed: Bool) -> Bool {
        guard Self.isEnabled, !quitAlreadyConfirmed else { return false }
        let daemonSocketAlive = Self.unixSocketAccepts(path: daemonSocketPath)
        return TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
            flagEnabled: Self.isEnabled,
            quitAlreadyConfirmed: quitAlreadyConfirmed,
            daemonSocketAlive: daemonSocketAlive,
            liveTerminalIDs: daemonSocketAlive ? liveTerminalIDs() : nil
        )
    }

    /// Truly stops the daemon session for quit: closes every live terminal
    /// (ending the session-owned shell processes), then stops the server.
    /// Runs off the main actor; each CLI call is individually bounded, so a
    /// wedged daemon cannot hang quit indefinitely.
    func stopDaemonSessionForQuit() async {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        let session = sessionName
        let terminalIDs = (liveTerminalIDs() ?? []).sorted()
        cachedTerminalIDs = nil
        let commands = TuiTerminalAttachPolicy.sessionStopCommands(
            sessionName: session,
            terminalIDs: terminalIDs
        )
        logSpike("quitStop.begin session=\(session) terminals=\(terminalIDs.count)")
        await Task.detached(priority: .userInitiated) {
            for arguments in commands {
                _ = TuiTerminalAttachBridge.runCLI(binary: binary, arguments: arguments, timeout: 10)
            }
        }.value
        logSpike("quitStop.done session=\(session)")
    }

    /// Whether closing the tab backed by `terminalID` must ask first,
    /// consulting the DAEMON terminal's real process state (the local surface
    /// child is the always-running attach client, so the app's process-based
    /// heuristic would prompt for an idle shell). Returns nil when the daemon
    /// cannot be queried so the caller falls back to the existing prompt
    /// behavior instead of silently skipping confirmation. Blocks the main
    /// actor on one short bounded CLI call (same spike contract as the other
    /// bridge calls); a 2s per-terminal cache absorbs the repeated
    /// close-gating checks of a single gesture.
    func closeConfirmationRequired(terminalID: String) -> Bool? {
        guard Self.isEnabled else { return nil }
        if let cached = cachedCloseConfirmations[terminalID],
           Date().timeIntervalSince(cached.fetchedAt) < 2 {
            return cached.required
        }
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary),
              Self.unixSocketAccepts(path: daemonSocketPath) else {
            logSpike("closeConfirm.unavailable terminal=\(terminalID)")
            return nil
        }
        let output = Self.runCLI(
            binary: binary,
            arguments: TuiTerminalAttachPolicy.processShowArguments(
                sessionName: sessionName,
                terminalID: terminalID
            ),
            timeout: 5
        )
        switch TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: output) {
        case .prompt:
            cachedCloseConfirmations[terminalID] = (true, Date())
            logSpike("closeConfirm.decision terminal=\(terminalID) required=1")
            return true
        case .noPrompt:
            cachedCloseConfirmations[terminalID] = (false, Date())
            logSpike("closeConfirm.decision terminal=\(terminalID) required=0")
            return false
        case .unknown:
            logSpike("closeConfirm.decision terminal=\(terminalID) required=unknown")
            return nil
        }
    }

    /// Closes one daemon terminal after its GUI tab (or pane/workspace) was
    /// closed, so the close cannot orphan a live daemon terminal.
    /// Fire-and-forget off the main actor: a failure leaves the terminal
    /// adoptable (today's pre-fix behavior) and is only logged.
    func closeTerminalForClosedSurface(terminalID: String) {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        cachedTerminalIDs = nil
        cachedCloseConfirmations.removeValue(forKey: terminalID)
        let arguments = TuiTerminalAttachPolicy.terminalCloseArguments(
            sessionName: sessionName,
            terminalID: terminalID
        )
        logSpike("surfaceClose.begin terminal=\(terminalID)")
        Task.detached(priority: .utility) { [terminalID] in
            let output = TuiTerminalAttachBridge.runCLI(binary: binary, arguments: arguments, timeout: 10)
            Self.logSpikeStatic("surfaceClose.done terminal=\(terminalID) ok=\(output != nil ? 1 : 0)")
        }
    }

    /// The attach command for a terminal id this bridge (or a previous app
    /// run) provisioned.
    func attachCommand(terminalID: String) -> String {
        TuiTerminalAttachPolicy.attachCommand(
            binaryPath: Self.binaryPath,
            sessionName: sessionName,
            terminalID: terminalID,
            configPath: Self.bridgeConfigPath
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
        process.arguments = TuiTerminalAttachPolicy.daemonStartArguments(sessionName: session)
        process.environment = Self.bridgeEnvironment
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
        guard let output = Self.runCLI(
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
    private nonisolated static func runCLI(binary: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = bridgeEnvironment
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

    private nonisolated static func logSpikeStatic(_ message: @autoclosure () -> String) {
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
