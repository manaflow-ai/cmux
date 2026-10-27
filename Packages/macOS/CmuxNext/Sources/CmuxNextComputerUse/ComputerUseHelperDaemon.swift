public import AppKit
public import CmuxNextAgentActivity
public import CmuxNextSettings
import Darwin
import Foundation
public import Observation
import os
public import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
        // A completion dropped without an answer is a helper that did not start (nil).
        return try? await withOnceContinuation { (continuation: OnceContinuation<pid_t?, OnceContinuationError>) in
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
/// `state` is observable: Computer Use Setup follows it.
@MainActor
@Observable
public final class ComputerUseHelperDaemon {
    public enum State: Equatable {
        case off
        /// On, but no Developer ID signed helper is installed (or it did not start).
        case unavailable
        case running(pid_t)
    }

    /// The app's helper. One per process.
    public static let shared = ComputerUseHelperDaemon()

    public private(set) var state: State = .off
    @ObservationIgnored let socketPath: String
    @ObservationIgnored let stateDirectory: URL
    @ObservationIgnored private let identity: CuaHelperIdentity
    @ObservationIgnored private let candidates: @Sendable () -> [URL]
    @ObservationIgnored private let launcher: any ComputerUseHelperLaunching
    @ObservationIgnored private let manifestReader: CuaHelperManifestReader
    @ObservationIgnored private let ownerPID: pid_t
    @ObservationIgnored private let published = Mutex<[String: String]>([:])
    @ObservationIgnored private var agentToken: String?
    @ObservationIgnored private var hostToken: String?
    @ObservationIgnored private var generation = 0
    /// The follow of `computerUse` (``follow(_:mainWork:lanes:disabledByPolicy:)``).
    @ObservationIgnored private var observation: ServiceObservation<ComputerUseSettings?>?
    /// The newest value no apply has taken yet, with the policy read when it came.
    @ObservationIgnored private var wanted: (settings: ComputerUseSettings, disabledByPolicy: Bool)?
    /// The one run of ``apply(_:disabledByPolicy:)`` at a time; values that come while it runs wait in ``wanted``.
    @ObservationIgnored private var applying: Task<Void, Never>?
    /// The helper v2 (`computerUse.driver = "upstream"`).
    @ObservationIgnored public let upstream: ComputerUseHelperV2
    /// The app's lanes (``follow(_:mainWork:lanes:disabledByPolicy:)``): the helper's signature checks run on their system lane.
    @ObservationIgnored private var lanes: (any MayBlockRunner)?

    init(identity: CuaHelperIdentity = CuaHelperIdentity(),
         candidates: @escaping @Sendable () -> [URL] = { CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild) },
         launcher: any ComputerUseHelperLaunching = WorkspaceHelperLauncher(),
         manifestReader: CuaHelperManifestReader = .shared,
         ownerPID: pid_t = getpid(),
         socketPath: String = ComputerUseHelperDaemon.defaultSocketPath(),
         stateDirectory: URL = ComputerUseHelperDaemon.defaultStateDirectory(),
         upstream: ComputerUseHelperV2? = nil) {
        self.upstream = upstream ?? ComputerUseHelperV2()
        self.identity = identity
        self.candidates = candidates
        self.launcher = launcher
        self.manifestReader = manifestReader
        self.ownerPID = ownerPID
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
    }

    /// What a child this app spawns for agents (acpmux) gets in its spawn
    /// environment while the helper runs: the socket and the agent token,
    /// never the host token. Empty while off. Any thread may read it
    /// (spawn paths run off the main actor); only this daemon writes it.
    public nonisolated var childEnvironment: [String: String] {
        published.withLock { $0 }
    }

    /// The socket and the agent token, keyed as a child reads them.
    static func childEnvironment(socketPath: String, agentToken: String) -> [String: String] {
        [AgentActivitySocketSource.Configuration.socketEnvironmentKey: socketPath,
         AgentActivitySocketSource.Configuration.authTokenEnvironmentKey: agentToken]
    }

    /// The socket and both tokens for this app's own readers (onboarding,
    /// the Agent Activity pane) while the helper runs.
    public var configuration: AgentActivitySocketSource.Configuration? {
        guard case .running = state else { return nil }
        return AgentActivitySocketSource.Configuration(socketPath: socketPath, authToken: agentToken,
                                                       hostAuthToken: hostToken, machineName: "")
    }

    /// Follows `computerUse.enabled`, `computerUse.driver` (and
    /// DisabledFeatures) for the app's life, from the settings file's first load.
    ///
    /// - Parameters:
    ///   - settings: The app's settings.
    ///   - mainWork: The main-thread scheduler the follow flushes on.
    ///   - lanes: The app's lanes: the helper v2 reads acpmux's signature on their system lane.
    ///   - disabledByPolicy: Whether DisabledFeatures turns Computer Use off, read with each value.
    ///
    /// Each value applies (a helper start or stop) one at a time, the newest one only.
    public func follow(_ settings: SettingsController, mainWork: MainWorkScheduler, lanes: any MayBlockRunner,
                       disabledByPolicy: @escaping () -> Bool) {
        self.lanes = lanes
        upstream.lanes = lanes
        observation?.cancel()
        // A service observation: the helper starts and stops whether or not anything shows it. `background`: no view
        // waits on it (a person's toggle in Settings flushes as user-blocking). Before the first load the snapshot
        // holds defaults: nothing applies, so a helper the file turns on is never stopped first.
        observation = ServiceObservation(.background, owner: "ComputerUseHelperDaemon.settings", on: mainWork) { [weak settings] in
            guard let settings, settings.loadCount > 0 else { return nil }
            return settings.snapshot.computerUse
        } apply: { [weak self] computerUse in
            guard let self, let computerUse else { return }
            want(computerUse, disabledByPolicy: disabledByPolicy())
        }
    }

    /// Takes `settings` as the next value to apply; starts the apply run when none runs.
    private func want(_ settings: ComputerUseSettings, disabledByPolicy: Bool) {
        wanted = (settings, disabledByPolicy)
        guard applying == nil else { return }
        // task-owner: the one apply run; it applies the newest value until none is left, and quit cancels it
        // main-hop-allow: only awaits the helpers' starts and stops, whose resolve, launch and spawn run off main
        applying = Task { [weak self] in await self?.applyWanted() }
    }

    /// Applies each wanted value in turn, the newest one only, until none is left.
    private func applyWanted() async {
        while let next = wanted, !Task.isCancelled {
            wanted = nil
            await apply(next.settings, disabledByPolicy: next.disabledByPolicy)
        }
        applying = nil
    }

    /// Which helper runs. The default (driver legacy) is today's path only:
    /// the helper v2 never starts.
    nonisolated static func route(_ settings: ComputerUseSettings, disabledByPolicy: Bool) -> (legacy: Bool, upstream: Bool) {
        let on = settings.enabled && !disabledByPolicy
        return (on && settings.driver == .legacy, on && settings.driver == .upstream)
    }

    /// Applies one settings value: stops the helper that is off first, then
    /// starts the one that is on.
    func apply(_ settings: ComputerUseSettings, disabledByPolicy: Bool) async {
        let route = Self.route(settings, disabledByPolicy: disabledByPolicy)
        if route.legacy {
            await upstream.apply(enabled: false)
            await apply(enabled: true)
        } else {
            await apply(enabled: false)
            await upstream.apply(enabled: route.upstream)
        }
    }

    /// Computer Use on: starts the signed helper (once); off: stops it.
    func apply(enabled: Bool) async {
        generation &+= 1
        let current = generation
        guard enabled else { return stop() }
        if case .running = state { return }
        let resolution = await Self.resolve(identity, candidates, on: lanes)
        guard current == generation else { return }
        guard case .signed(let helper) = resolution else {
            helperLogger.notice("Computer Use is on, but no Developer ID signed cmux Computer Use helper is installed")
            state = .unavailable
            return
        }
        // The helper's parent is launchd (LaunchServices), so it outlives a
        // crash of this app unless it watches this pid. Older helpers may
        // reject an unknown flag: pass it only when the manifest lists it.
        let capabilities = await manifestReader.capabilities(of: helper)
        guard current == generation, !Task.isCancelled else { return }
        let owner = capabilities.contains(CuaHelperManifestReader.ownerPIDCapability) ? ownerPID : nil
        guard prepareDirectories() else {
            state = .unavailable
            return
        }
        let agent = Self.makeToken()
        let host = Self.makeToken()
        let pid = await launcher.launch(helper, arguments: Self.arguments(socketPath: socketPath, ownerPID: owner),
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
    public func applicationWillTerminate() {
        observation?.cancel()
        observation = nil
        wanted = nil
        applying?.cancel()
        applying = nil
        generation &+= 1
        stop()
        upstream.terminateForQuit()
    }

    /// `serve` argv: the socket path and this app's pid only, never a token
    /// (argv is visible to every local user; tokens go in the environment).
    /// The helper removes an agent's cursor only when its session ends, so
    /// the idle fade is what clears it after a run (cx-ujus); 0 disables it.
    public nonisolated static func arguments(socketPath: String, ownerPID: pid_t? = nil) -> [String] {
        ["serve", "--socket", socketPath, "--no-permissions-gate", "--cursor-shape", "cmux", "--idle-hide-ms", "10000"]
            + (ownerPID.map { ["--owner-pid", String($0)] } ?? [])
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

    /// The helper to start: signature checks of the candidates, on `lanes`' system lane (no helper
    /// while the app has not wired its lanes).
    nonisolated static func resolve(_ identity: CuaHelperIdentity, _ candidates: @escaping @Sendable () -> [URL],
                                    on lanes: (any MayBlockRunner)?) async -> CuaHelperIdentity.Resolution {
        let none = CuaHelperIdentity.Resolution.unavailable(.noSignedHelperInstalled)
        guard let lanes else { return none }
        return (try? await lanes.runSystem(.userVisible) { identity.resolve(running: nil, installed: candidates()) }) ?? none
    }

    public nonisolated static var isDevBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").contains(".debug")
    }

    /// `<this user's temp dir>/cmux-cua/<scope>/cua.sock`: the per-user
    /// Darwin temp directory (`_CS_DARWIN_USER_TEMP_DIR`, 0700 and owned by
    /// the user, unlike the shared /tmp), one socket per app build (tag),
    /// short enough for a Unix socket address (~83 of 104 bytes).
    nonisolated static func defaultSocketPath(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> String {
        "\(userTemporaryDirectory())cmux-cua/\(scope(bundleID))/cua.sock"
    }

    /// The per-user Darwin temp directory, with a trailing slash. When
    /// confstr fails: /tmp/cmux-<uid>/, never $TMPDIR (one per user, so slot
    /// users on one Mac do not collide; the caller makes its 0700 directories
    /// there and checks them with fstat; the helper v2 accepts only the Darwin
    /// temp dir and /tmp).
    nonisolated static func userTemporaryDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return "/tmp/cmux-\(geteuid())/" }
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
