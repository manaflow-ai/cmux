import AppKit
import CmuxNextAgentActivity
import CmuxNextSettings
import Darwin
import Foundation
import os

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
/// children). Children see the socket and the agent token as
/// CMUX_NEXT_CUA_SOCKET and CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN; the host token
/// stays in this app. Off (the default, or DisabledFeatures) nothing starts,
/// and the helper is stopped when Computer Use turns off and when the app quits.
@MainActor
final class ComputerUseHelperDaemon {
    enum State: Equatable {
        case off
        /// On, but no Developer ID signed helper is installed (or it did not start).
        case unavailable
        case running(pid_t)
    }

    /// The app's helper. One per process: its exports go into this
    /// process's environment, which every child shares.
    static let shared = ComputerUseHelperDaemon()

    private(set) var state: State = .off
    let socketPath: String
    let stateDirectory: URL
    private let identity: CuaHelperIdentity
    private let candidates: @Sendable () -> [URL]
    private let launcher: any ComputerUseHelperLaunching
    private let exportEnvironment: (String, String?) -> Void
    private var agentToken: String?
    private var hostToken: String?
    private var generation = 0
    private var observation: Task<Void, Never>?

    init(identity: CuaHelperIdentity = CuaHelperIdentity(),
         candidates: @escaping @Sendable () -> [URL] = { CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild) },
         launcher: any ComputerUseHelperLaunching = WorkspaceHelperLauncher(),
         socketPath: String = ComputerUseHelperDaemon.defaultSocketPath(),
         stateDirectory: URL = ComputerUseHelperDaemon.defaultStateDirectory(),
         exportEnvironment: @escaping (String, String?) -> Void = ComputerUseHelperDaemon.setProcessEnvironment) {
        self.identity = identity
        self.candidates = candidates
        self.launcher = launcher
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
        self.exportEnvironment = exportEnvironment
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
        exportEnvironment(AgentActivitySocketSource.Configuration.socketEnvironmentKey, socketPath)
        exportEnvironment(AgentActivitySocketSource.Configuration.authTokenEnvironmentKey, agent)
    }

    /// Stops the helper this app started (exact pid) and withdraws the exports.
    func stop() {
        if case .running(let pid) = state { launcher.terminate(pid) }
        state = .off
        agentToken = nil
        hostToken = nil
        exportEnvironment(AgentActivitySocketSource.Configuration.socketEnvironmentKey, nil)
        exportEnvironment(AgentActivitySocketSource.Configuration.authTokenEnvironmentKey, nil)
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

    /// `/tmp/cmux-cua-<uid>/<scope>/cua.sock`: short enough for a Unix
    /// socket, private to this user, one per app build (tag).
    nonisolated static func defaultSocketPath(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> String {
        "/tmp/cmux-cua-\(getuid())/\(scope(bundleID))/cua.sock"
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

    /// Exports to this process's environment, which every child inherits
    /// (acpmux, terminals). Main actor only, before any child it is meant for starts.
    nonisolated static func setProcessEnvironment(_ key: String, _ value: String?) {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }

    /// The socket directory (0700, this user's) and the helper's state directory.
    private func prepareDirectories() -> Bool {
        let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            for directory in [socketDirectory.deletingLastPathComponent(), socketDirectory, stateDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            unlink(socketPath)
            return true
        } catch {
            helperLogger.error("cmux Computer Use helper directories: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
