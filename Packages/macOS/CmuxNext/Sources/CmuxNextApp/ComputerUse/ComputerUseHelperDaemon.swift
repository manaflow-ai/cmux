import AppKit
import CmuxNextAgentActivity
import CmuxNextSettings
import Darwin
import Foundation
import os
import Synchronization

private let helperLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Starts the cmux-cua daemon in a helper app (LaunchServices in the App, a fake in tests).
@MainActor
protocol ComputerUseHelperLaunching: AnyObject {
    /// Launches a new instance of `app` (never activated); its pid, or nil.
    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t?
    func terminate(_ pid: pid_t)
}

/// LaunchServices launches: the helper is its own app, so macOS attributes
/// its Accessibility and Screen Recording to its Developer ID identity, not
/// to cmux.
@MainActor
final class WorkspaceHelperLauncher: ComputerUseHelperLaunching {
    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.arguments = arguments
        configuration.environment = environment
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
                if let error { helperLogger.error("cmux Computer Use helper did not start: \(error.localizedDescription, privacy: .public)") }
                continuation.resume(returning: running?.processIdentifier)
            }
        }
    }

    func terminate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }
}

/// The cmux Computer Use helper this app runs while Computer Use is on.
///
/// Only a Developer ID signed helper starts (`CuaHelperIdentity`): a dev
/// build uses the installed NIGHTLY, RC or release helper, a release build
/// its own. It serves `cmux-cua serve --socket <tag-scoped path>` with token
/// authorization only (agents run under acpmux, not as this app's
/// children). The acpmux daemon this app spawns gets the socket and the
/// agent token as CMUX_NEXT_CUA_SOCKET and CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN
/// in its spawn environment (`childEnvironment`); the host token stays in
/// this app. This process's own environment is never written: libghostty
/// keeps a slice of `environ` from launch, so a setenv or unsetenv after
/// launch left it reading a NULL or freed entry (SIGSEGV in
/// ghostty_config_finalize). Off (the default, or DisabledFeatures) nothing
/// starts, and the helper is stopped when Computer Use turns off and when the app quits.
@MainActor
final class ComputerUseHelperDaemon {
    enum State: Equatable {
        case off
        /// On, but no Developer ID signed helper is installed (or it did not start).
        case unavailable
        case running(pid_t)
    }

    /// The app's helper. One per process.
    static let shared = ComputerUseHelperDaemon()

    private(set) var state: State = .off
    let socketPath: String
    let stateDirectory: URL
    private let identity: CuaHelperIdentity
    private let candidates: @Sendable () -> [URL]
    private let launcher: any ComputerUseHelperLaunching
    private let published = Mutex<[String: String]>([:])
    private var agentToken: String?
    private var hostToken: String?
    private var generation = 0
    private var observation: Task<Void, Never>?

    init(identity: CuaHelperIdentity = CuaHelperIdentity(),
         candidates: @escaping @Sendable () -> [URL] = { CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild) },
         launcher: any ComputerUseHelperLaunching = WorkspaceHelperLauncher(),
         socketPath: String = ComputerUseHelperDaemon.defaultSocketPath(),
         stateDirectory: URL = ComputerUseHelperDaemon.defaultStateDirectory()) {
        self.identity = identity
        self.candidates = candidates
        self.launcher = launcher
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
    }

    /// What a child this app spawns for agents (acpmux) gets in its spawn
    /// environment while the helper runs: the socket and the agent token,
    /// never the host token. Empty while off. Any thread may read it
    /// (spawn paths run off the main actor); only this daemon writes it.
    nonisolated var childEnvironment: [String: String] {
        published.withLock { $0 }
    }

    /// The socket and the agent token, keyed as a child reads them.
    static func childEnvironment(socketPath: String, agentToken: String) -> [String: String] {
        [AgentActivitySocketSource.Configuration.socketEnvironmentKey: socketPath,
         AgentActivitySocketSource.Configuration.authTokenEnvironmentKey: agentToken]
    }

    /// The socket and both tokens for this app's own readers (onboarding,
    /// the Agent Activity pane) while the helper runs.
    var configuration: AgentActivitySocketSource.Configuration? {
        guard case .running = state else { return nil }
        return AgentActivitySocketSource.Configuration(socketPath: socketPath, authToken: agentToken,
                                                       hostAuthToken: hostToken, machineName: "")
    }

    /// Follows `computerUse.enabled` (and DisabledFeatures) for the app's life.
    func follow(_ settings: SettingsController, disabledByPolicy: @escaping () -> Bool) {
        observation?.cancel()
        observation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await enabled in Observations({ settings.snapshot.computerUse.enabled }) {
                guard let self else { return }
                await apply(enabled: enabled && !disabledByPolicy())
            }
        }
    }

    /// Computer Use on: starts the signed helper (once); off: stops it.
    func apply(enabled: Bool) async {
        generation &+= 1
        let current = generation
        guard enabled else { return stop() }
        if case .running = state { return }
        let resolution = await Self.resolve(identity, candidates)
        guard current == generation else { return }
        guard case .signed(let helper) = resolution else {
            helperLogger.notice("Computer Use is on, but no Developer ID signed cmux Computer Use helper is installed")
            state = .unavailable
            return
        }
        guard prepareDirectories() else {
            state = .unavailable
            return
        }
        let agent = Self.makeToken()
        let host = Self.makeToken()
        let pid = await launcher.launch(helper, arguments: Self.arguments(socketPath: socketPath),
                                        environment: Self.environment(stateDirectory: stateDirectory, agentToken: agent, hostToken: host))
        guard current == generation else {
            if let pid { launcher.terminate(pid) }
            return
        }
        guard let pid else {
            state = .unavailable
            return
        }
        agentToken = agent
        hostToken = host
        state = .running(pid)
        helperLogger.notice("cmux Computer Use helper started from \(helper.path, privacy: .public)")
        let exported = Self.childEnvironment(socketPath: socketPath, agentToken: agent)
        published.withLock { $0 = exported }
    }

    /// Stops the helper this app started (exact pid) and withdraws the child environment.
    func stop() {
        if case .running(let pid) = state { launcher.terminate(pid) }
        state = .off
        agentToken = nil
        hostToken = nil
        published.withLock { $0 = [:] }
    }

    /// App quit: no further starts, and the helper stops.
    func applicationWillTerminate() {
        observation?.cancel()
        observation = nil
        generation &+= 1
        stop()
    }

    nonisolated static func arguments(socketPath: String) -> [String] {
        ["serve", "--socket", socketPath, "--no-permissions-gate", "--cursor-shape", "cmux", "--idle-hide-ms", "0"]
    }

    /// The helper's environment: no CMUX_CUA_SOCKET_AUTHORIZED_ROOT_* (agents
    /// run under acpmux, detached from this app), token authorization only.
    nonisolated static func environment(stateDirectory: URL, agentToken: String, hostToken: String) -> [String: String] {
        [
            "CMUX_CUA_EXTERNAL_PERMISSION_FLOW": "1",
            "CMUX_CUA_PERMISSIONS_GATE": "0",
            "CMUX_CUA_RESPONSIBILITY_DISCLAIMED": "1",
            "CMUX_CUA_TELEMETRY_ENABLED": "false",
            "CMUX_CUA_UPDATE_CHECK": "false",
            "CMUX_CUA_CURSOR_LABEL": "cmux",
            "CMUX_CUA_STATE_DIR": stateDirectory.path,
            "CMUX_CUA_SOCKET_AUTH_TOKEN": agentToken,
            "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN": hostToken,
        ]
    }

    @concurrent nonisolated static func resolve(_ identity: CuaHelperIdentity,
                                                _ candidates: @Sendable () -> [URL]) async -> CuaHelperIdentity.Resolution {
        identity.resolve(running: nil, installed: candidates())
    }

    nonisolated static var isDevBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").contains(".debug")
    }

    /// `<this user's temp dir>/cmux-cua/<scope>/cua.sock`: the per-user
    /// Darwin temp directory (`_CS_DARWIN_USER_TEMP_DIR`, 0700 and owned by
    /// the user, unlike the shared /tmp), one socket per app build (tag),
    /// short enough for a Unix socket address (~83 of 104 bytes).
    nonisolated static func defaultSocketPath(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> String {
        "\(userTemporaryDirectory())cmux-cua/\(scope(bundleID))/cua.sock"
    }

    /// The per-user Darwin temp directory, with a trailing slash.
    nonisolated static func userTemporaryDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return NSTemporaryDirectory() }
        let path = String(cString: buffer)
        return path.hasSuffix("/") ? path : path + "/"
    }

    nonisolated static func defaultStateDirectory(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux/cmux-cua/runtime/\(scope(bundleID))/state", directoryHint: .isDirectory)
    }

    /// A stable 16-hex scope for a bundle id (FNV-1a).
    nonisolated static func scope(_ bundleID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bundleID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", hash)
    }

    nonisolated static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The socket directory and its parent (cmux-cua under the user's temp directory)
    /// and the helper's state directory: each must be a real directory owned
    /// by this user and is set to 0700. A symlink or another user's directory
    /// there could hand the helper's socket to someone else, so nothing starts.
    private func prepareDirectories() -> Bool {
        let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        for directory in [socketDirectory.deletingLastPathComponent(), socketDirectory, stateDirectory] {
            guard Self.makePrivateDirectory(directory.path) else {
                helperLogger.error("cmux Computer Use helper: \(directory.path, privacy: .public) is not a private directory of this user")
                return false
            }
        }
        unlink(socketPath)
        return true
    }

    /// Creates `path` (0700; missing parents get the default mode) or takes
    /// the existing one, then checks it without following a symlink: a
    /// directory owned by this user, set to 0700. Only `path` itself is
    /// changed, never a parent.
    nonisolated static func makePrivateDirectory(_ path: String) -> Bool {
        if mkdir(path, 0o700) != 0 {
            switch errno {
            case EEXIST: break
            case ENOENT:
                let parent = (path as NSString).deletingLastPathComponent
                guard (try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)) != nil,
                      mkdir(path, 0o700) == 0 || errno == EEXIST else { return false }
            default: return false
            }
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else { return false }
        return info.st_mode & 0o777 == 0o700 || fchmod(descriptor, 0o700) == 0
    }
}
