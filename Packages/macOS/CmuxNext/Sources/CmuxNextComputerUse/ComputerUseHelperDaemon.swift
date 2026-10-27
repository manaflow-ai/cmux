public import AppKit
public import CmuxNextAgentActivity
public import CmuxNextSettings
import Darwin
import Foundation
public import Observation
import os
import CmuxNextCompat

private let helperLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Starts the cmux-cua daemon in a helper app (LaunchServices in the App, a fake in tests).
@MainActor
protocol ComputerUseHelperLaunching: AnyObject {
    /// Launches a new instance of `app` (never activated); its pid, or nil.
    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t?
    func terminate(_ pid: pid_t)
    /// Calls `onExit` once, on the main actor, when `pid` exits; the returned
    /// closure cancels the watch (`ComputerUseHelperExitWatch`).
    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void
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
/// this app. The agent token lives for this app launch, not for one helper
/// start, and the endpoint is published while Computer Use is off too: an
/// agent's computer use server gets them once, when its chat starts, so a
/// chat started before the person turned Computer Use on (or before a helper
/// restart) still reaches the helper afterwards. With no helper running the
/// token opens nothing. This process's own environment is never written: libghostty
/// keeps a slice of `environ` from launch, so a setenv or unsetenv after
/// launch left it reading a NULL or freed entry (SIGSEGV in
/// ghostty_config_finalize). Off (the default, or DisabledFeatures) nothing
/// starts, and the helper is stopped when Computer Use turns off and when the app quits.
/// A helper that exits by itself (macOS "Quit & Reopen" after a privacy
/// grant, a crash) starts again within a budget, then is `.failed`.
/// `state` is observable: Computer Use Setup follows it.
@MainActor
@Observable
public final class ComputerUseHelperDaemon {
    public enum State: Equatable {
        case off
        /// On, but no Developer ID signed helper is installed (or it did not start).
        case unavailable
        case running(pid_t)
        /// On, but the helper kept exiting by itself (`helperExited(_:)`).
        /// Restart Helper, or Computer Use off and on, starts it again.
        case failed
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
    @ObservationIgnored private let staging: ComputerUseHelperStaging
    @ObservationIgnored private let ownerPID: pid_t
    @ObservationIgnored private let published = Mutex<[String: String]>([:])
    /// Gets the published endpoint each time it changes (the App pushes it to its acpmux).
    @ObservationIgnored public var onEndpointChange: (@MainActor ([String: String]) -> Void)?
    /// The agent token of this app launch: every helper start serves it.
    /// Replaced only when a launched helper fails its running check.
    @ObservationIgnored private var launchAgentToken = ComputerUseHelperDaemon.makeToken()
    @ObservationIgnored private var agentToken: String?
    @ObservationIgnored private var hostToken: String?
    @ObservationIgnored private var requestedEnabled = false
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let restarts: ComputerUseHelperRestarts
    /// The helper v2 (`computerUse.driver = "upstream"`).
    @ObservationIgnored public let upstream: ComputerUseHelperV2

    init(identity: CuaHelperIdentity = CuaHelperIdentity(),
         candidates: @escaping @Sendable () -> [URL] = { CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild) },
         launcher: any ComputerUseHelperLaunching = WorkspaceHelperLauncher(),
         manifestReader: CuaHelperManifestReader = .shared,
         staging: ComputerUseHelperStaging = .legacy(),
         ownerPID: pid_t = getpid(),
         socketPath: String = ComputerUseHelperDaemon.defaultSocketPath(),
         stateDirectory: URL = ComputerUseHelperDaemon.defaultStateDirectory(),
         clock: any Clock<Duration> = ContinuousClock(),
         upstream: ComputerUseHelperV2? = nil) {
        self.upstream = upstream ?? ComputerUseHelperV2()
        self.restarts = ComputerUseHelperRestarts(clock: clock)
        self.identity = identity
        self.candidates = candidates
        self.launcher = launcher
        self.manifestReader = manifestReader
        self.staging = staging
        self.ownerPID = ownerPID
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
        // Published from launch with the default driver, before settings
        // load: an agent pane that connects first must not enroll an empty
        // endpoint. The first settings value withdraws it under the helper v2
        // or DisabledFeatures.
        publish(true)
    }

    /// What a child this app spawns for agents (acpmux) gets in its spawn
    /// environment: the socket and the agent token, never the host token.
    /// Set while the legacy driver is chosen, on or off; empty under the
    /// helper v2 or DisabledFeatures. Any thread may read it (spawn paths
    /// run off the main actor); only this daemon writes it.
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
    /// DisabledFeatures) for the app's life.
    public func follow(_ settings: SettingsController, disabledByPolicy: @escaping () -> Bool) {
        observation?.cancel()
        observation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await computerUse in ObservationStream({ settings.snapshot.computerUse }) {
                guard let self else { return }
                await apply(computerUse, disabledByPolicy: disabledByPolicy())
            }
        }
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
        guard !quitting, !Task.isCancelled else { return }
        let route = Self.route(settings, disabledByPolicy: disabledByPolicy)
        publish(!disabledByPolicy && settings.driver == .legacy)
        if route.legacy {
            await upstream.apply(enabled: false)
            guard !quitting, !Task.isCancelled else { return }
            await apply(enabled: true)
        } else {
            await apply(enabled: false)
            guard !quitting, !Task.isCancelled else { return }
            await upstream.apply(enabled: route.upstream)
        }
    }

    /// Computer Use on: starts the signed helper (once); off: stops it.
    func apply(enabled: Bool) async {
        await request(enabled: enabled).value
    }

    /// Settings changes join one transition, including a launch still in flight.
    func request(enabled: Bool) -> Task<Void, Never> {
        requestedEnabled = enabled && !quitting
        if let transition { return transition }
        let task = Task { [self] in
            await settle()
            transition = nil
        }
        transition = task
        return task
    }

    /// Applies the wanted state once. A stop is synchronous, so the wanted
    /// state cannot change during it; a start awaits, and a settings change
    /// that arrived meanwhile gets one more pass. It ends when the setting
    /// stops changing.
    private func settle() async {
        let wanted = requestedEnabled
        if wanted { await start() } else { stop() }
        if wanted != requestedEnabled { await settle() }
    }

    private func start() async {
        if case .running = state { return }
        let resolution = await Self.resolve(identity, candidates)
        guard requestedEnabled else { return }
        guard case .signed(let helper) = resolution else {
            helperLogger.notice("Computer Use is on, but no Developer ID signed cmux Computer Use helper is installed")
            state = .unavailable
            return
        }
        let runningCheck = await staging.runningCheck(for: helper)
        guard requestedEnabled else { return }
        guard let runningCheck else {
            helperLogger.error("cmux Computer Use helper: cannot read the code requirement")
            state = .unavailable
            return
        }
        // Launch a verified copy outside this app: nested in it, macOS checks
        // the helper's Screen Recording as this app (ComputerUseHelperStaging).
        let staged = await staging.stage(helper)
        guard requestedEnabled else { return }
        guard let staged else {
            helperLogger.error("Computer Use is on, but the cmux Computer Use helper copy could not be made or verified")
            state = .unavailable
            return
        }
        // The helper's parent is launchd (LaunchServices), so it outlives a
        // crash of this app unless it watches this pid. Older helpers may
        // reject an unknown flag: pass it only when the manifest lists it.
        let capabilities = await manifestReader.capabilities(of: staged)
        guard requestedEnabled else { return }
        let owner = capabilities.contains(CuaHelperManifestReader.ownerPIDCapability) ? ownerPID : nil
        // The launcher holds the scope lock and prepares its directories (ComputerUseHelperScope).
        let agent = launchAgentToken
        let host = Self.makeToken()
        let pid = await launcher.launch(staged, arguments: Self.arguments(socketPath: socketPath, ownerPID: owner),
                                        environment: Self.environment(stateDirectory: stateDirectory, agentToken: agent, hostToken: host))
        guard requestedEnabled else {
            if let pid { launcher.terminate(pid) }
            return
        }
        guard let pid else {
            state = .unavailable
            return
        }
        let trusted = await staging.acceptsRunningProcess(pid, check: runningCheck)
        if !trusted { replaceAgentToken() }
        guard requestedEnabled else {
            launcher.terminate(pid)
            return
        }
        guard trusted else {
            launcher.terminate(pid)
            state = .unavailable
            helperLogger.error("cmux Computer Use helper pid \(pid, privacy: .public) failed its signature check")
            return
        }
        agentToken = agent
        hostToken = host
        state = .running(pid)
        restarts.watch(launcher.watchExit(of: pid) { [weak self] in self?.helperExited(pid) })
        helperLogger.notice("cmux Computer Use helper started from \(staged.path, privacy: .public)")
    }

    /// The helper exited and this app did not stop it. Its tokens go as on a
    /// stop, and the setup reads again (state leaves `.running`). While
    /// Computer Use is on it starts again, so after "Quit & Reopen" the new
    /// helper reads the new grant; an exit loop ends in `.failed`, where the
    /// setup offers Restart Helper.
    private func helperExited(_ pid: pid_t) {
        guard case .running(let running) = state, running == pid else { return }
        agentToken = nil
        hostToken = nil
        guard requestedEnabled, !quitting else {
            state = .off
            return
        }
        guard restarts.takeRestart() else {
            helperLogger.error("cmux Computer Use helper pid=\(pid, privacy: .public) exited again within a minute; not starting it again")
            state = .failed
            return
        }
        helperLogger.notice("cmux Computer Use helper pid=\(pid, privacy: .public) exited; starting it again")
        state = .off
        // The start joins the settings transition, which owns its task.
        _ = request(enabled: true)
    }

    /// Restarts the legacy helper. The caller checks the current setting and policy.
    public func restartLegacy() async {
        stop()
        await apply(enabled: true)
    }

    /// Stops the helper this app started (exact pid). The endpoint stays
    /// published: a later start serves the same socket and agent token. Its
    /// exit watch ends first, so this exit starts nothing.
    func stop() {
        restarts.stopped()
        if case .running(let pid) = state { launcher.terminate(pid) }
        state = .off
        agentToken = nil
        hostToken = nil
    }

    /// A process that failed its running check got the agent token in its
    /// environment at launch. A new token replaces it, so the next helper
    /// does not serve it; a published endpoint moves to the new token.
    private func replaceAgentToken() {
        launchAgentToken = Self.makeToken()
        let isPublished = published.withLock { !$0.isEmpty }
        if isPublished { publish(true) }
    }

    /// Publishes this launch's endpoint to the children this app spawns, or withdraws it.
    private func publish(_ endpoint: Bool) {
        let exported = endpoint ? Self.childEnvironment(socketPath: socketPath, agentToken: launchAgentToken) : [:]
        published.withLock { $0 = exported }
    }

    /// App quit: no further starts, and the helper stops.
    public func applicationWillTerminate() {
        observation?.cancel()
        observation = nil
        quitting = true
        requestedEnabled = false
        stop()
        publish(false)
        upstream.terminateForQuit()
    }

    /// `serve` argv: the socket path and this app's pid only, never a token
    /// (argv is visible to every local user; tokens go in the environment).
    /// The helper removes an agent's cursor only when its session ends, so
    /// the idle fade is what clears it after a run (cx-ujus); 0 disables it.
    /// The cursor glides in a fixed 150 ms and waits 30 ms after a click.
    /// The helper's default is speed-based: a run's first click took 3.3 to
    /// 3.6 s as the cursor crossed to the app's display, later clicks 0.2 to
    /// 0.9 s each. `--glide-ms` and `--dwell-ms` set the motion every new
    /// session cursor starts with.
    public nonisolated static func arguments(socketPath: String, ownerPID: pid_t? = nil, motion: Bool = false) -> [String] {
        ["serve", "--socket", socketPath, "--no-permissions-gate", "--cursor-shape", "cmux", "--idle-hide-ms", "10000",
         "--glide-ms", "150", "--dwell-ms", "30"]
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

    @concurrent nonisolated static func resolve(_ identity: CuaHelperIdentity,
                                                _ candidates: @Sendable () -> [URL]) async -> CuaHelperIdentity.Resolution {
        identity.resolve(running: nil, installed: candidates())
    }

    /// The verified copy of the helper this app build launches, when it is
    /// in place (the "drag this app" tile names it). Off the main actor.
    public nonisolated static func stagedHelper() async -> URL? {
        await ComputerUseHelperStaging.legacy().existingCopy(named: CuaHelperIdentity.appName)
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
        cuaRoot(home: FileManager.default.homeDirectoryForCurrentUser)
            .appending(path: "runtime/\(scope(bundleID))/state", directoryHint: .isDirectory)
    }

    /// The cmux-cua folder every build shares with classic cmux; each build's
    /// own items in it are named by its scope.
    nonisolated static func cuaRoot(home: URL) -> URL {
        home.appending(path: "Library/Application Support/cmux/cmux-cua", directoryHint: .isDirectory)
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
