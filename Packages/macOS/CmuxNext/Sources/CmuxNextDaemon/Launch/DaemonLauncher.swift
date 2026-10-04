public import Foundation
import os
import Synchronization

/// Locates the bundled cmux-tui binary and runs `cmux-tui --session <S>
/// --json server ensure`, which returns a running owner or spawns a detached
/// (`setsid`) one that survives app quit.
///
/// Isolation: release builds use session `cmux-app`; a tagged dev build
/// (`CMUX_TAG`) uses `cmux-app-<tag>` and a tag-private `CMUX_TUI_STATE_DIR`,
/// so dev state never shares a root with release state. `run_ensure` does not
/// forward `--state`, so the env var is the only way the owner sees it.
public struct DaemonLauncher: Sendable {
    public struct Configuration: Sendable, Hashable {
        public var binary: URL
        public var session: String
        /// Nil keeps cmux-tui's default state root for the session.
        public var stateDirectory: URL?
        /// Optional daemon config file (`CMUX_TUI_CONFIG`).
        public var configFile: URL?
        /// Base of the owner's socket directory, sent as `TMPDIR` (cmux-tui
        /// puts sockets under `$XDG_RUNTIME_DIR` or `$TMPDIR`). The owner's
        /// identity is the state directory, so the socket must not move with
        /// whatever `TMPDIR` the app happened to be launched with: an app
        /// launched with another `TMPDIR` would miss the live owner, spawn a
        /// second one that cannot take the session lock, and never connect.
        /// Defaults to the user's Darwin temp directory, which is fixed per user.
        public var runtimeBase: URL
        /// `server ensure --terminal-reap-grace-seconds`: how long the owner
        /// keeps a terminal with no tab before it ends it (`keep` exempts
        /// one). cmux-tui reaps only when started with the option; the app
        /// keeps a closed tab's terminal 30 s for Reopen Closed Tab and a
        /// closed workspace, then ends it so closed tabs never leak PTYs.
        /// An owner that is already running keeps the grace it started with.
        public var terminalReapGraceSeconds: UInt32
        /// The socket the last connection used (`DaemonSocketMemory`). The
        /// first endpoint request returns it when it accepts a connection,
        /// skipping the `server status` spawn; later ones (reconnects) run
        /// `ensure`, which restarts a crashed daemon.
        public var rememberedSocket: String?

        public init(binary: URL, session: String, stateDirectory: URL? = nil, configFile: URL? = nil,
                    runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(),
                    terminalReapGraceSeconds: UInt32 = 30, rememberedSocket: String? = nil) {
            self.binary = binary
            self.session = session
            self.stateDirectory = stateDirectory
            self.configFile = configFile
            self.runtimeBase = runtimeBase
            self.terminalReapGraceSeconds = terminalReapGraceSeconds
            self.rememberedSocket = rememberedSocket
        }
    }

    /// `server ensure --json` output.
    public struct EnsureResult: Sendable, Hashable, Decodable {
        /// `"running"` or `"started"`.
        public var status: String
        public var session: String
        public var socket: String
        public var pid: Int32
        public var generation: DaemonGeneration
        public var message: String?

        public var endpoint: DaemonEndpoint {
            DaemonEndpoint(socketPath: socket, pid: pid, generation: generation)
        }
    }

    /// Environment variable that overrides the bundled binary (dev builds).
    public static let binaryOverrideKey = "CMUX_NEXT_TUI_BIN"

    public let configuration: Configuration
    /// `configuration.rememberedSocket` until the first endpoint request of
    /// any provider of this launcher takes it: the startup loop's retries
    /// and every reconnect then ask the owner (`ensure`), so a hung daemon
    /// behind a live socket cannot keep a retry loop away from `ensure`.
    private let rememberedSocket: RememberedSocket
    /// Version handoff state (`handOffIfStale`).
    let handoff = DaemonHandoffState()
    private let clock: any Clock<Duration>
    private let ensureTimeout: Duration
    private let environmentProvider: @Sendable () async -> [String: String]

    public init(
        configuration: Configuration,
        environment: @escaping @Sendable () async -> [String: String],
        ensureTimeout: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        rememberedSocket = RememberedSocket(configuration.rememberedSocket)
        self.environmentProvider = environment
        self.ensureTimeout = ensureTimeout
        self.clock = clock
    }

    /// The standard app launcher: bundled binary, session from the app's own
    /// tag (never an inherited `CMUX_TAG`), login-shell environment captured
    /// once per launch and remembered for the next (`LoginEnvironmentCache`). `terminalEnvironment` (the app's `CMUX_SOCKET_PATH`,
    /// `CMUX_BUNDLE_ID`, `CMUX_TAG`) reaches every shell the daemon spawns.
    public static func forApp(
        tag: String?,
        terminalEnvironment: [String: String],
        bundle: Bundle = .main,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        socketMemory: DaemonSocketMemory = DaemonSocketMemory()
    ) throws -> DaemonLauncher {
        let tag = tag.flatMap { $0.isEmpty ? nil : $0 }
        let binary = try resolveBinary(bundle: bundle, environment: processEnvironment)
        DaemonLaunchTimings.shared.mark("daemon.binary_resolved")
        let session = try sessionName(tag: tag)
        let stateDirectory = tag.map { tagStateDirectory(tag: $0) }
        let configuration = Configuration(binary: binary, session: session, stateDirectory: stateDirectory,
                                          rememberedSocket: socketMemory.socket(session: session))
        var overrides = terminalEnvironment
        if let stateDirectory { overrides["CMUX_TUI_STATE_DIR"] = stateDirectory.path }
        return DaemonLauncher(configuration: configuration, environment: appEnvironment(
            cache: .shared, base: processEnvironment, overrides: overrides))
    }

    /// The app launcher's `server ensure` environment: the login
    /// environment `cache` has now (`LoginEnvironmentCache.immediate()`:
    /// this launch's capture, else the one remembered from the last launch,
    /// else the app's own), filtered, plus the app's identity keys and
    /// `overrides`. It never waits for `$SHELL -l -i`, which takes 5-17 s
    /// on some setups; the app's terminals do not depend on it, because
    /// each carries its own login `env` (`TerminalEnvironment.shared`).
    static func appEnvironment(
        cache: LoginEnvironmentCache,
        base: [String: String],
        overrides: [String: String]
    ) -> @Sendable () async -> [String: String] {
        {
            DaemonLaunchTimings.shared.mark("daemon.login_env_start")
            let login = await cache.immediate()
            DaemonLaunchTimings.shared.mark("daemon.login_env_end")
            return LoginEnvironment.shared.daemonEnvironment(login: login, base: base, overrides: overrides)
        }
    }

    // MARK: - Resolution

    /// `CMUX_NEXT_TUI_BIN`, then `Contents/Resources/bin/cmux-tui`.
    public static func resolveBinary(bundle: Bundle, environment: [String: String]) throws -> URL {
        var searched: [String] = []
        let fileManager = FileManager.default
        if let override = environment[binaryOverrideKey], !override.isEmpty {
            searched.append(override)
            if fileManager.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        }
        if let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent("bin/cmux-tui")
            searched.append(bundled.path)
            if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        throw DaemonError.binaryNotFound(searched: searched)
    }

    /// `cmux-app`, or `cmux-app-<tag>` with the tag reduced to a safe single
    /// path component.
    public static func sessionName(tag: String?) throws -> String {
        guard let tag else { return "cmux-app" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = String(tag.map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard !cleaned.isEmpty else { throw DaemonError.invalidSessionName(tag) }
        return "cmux-app-\(cleaned)"
    }

    /// `~/Library/Application Support/cmux/tags/<tag>/tui`.
    public static func tagStateDirectory(tag: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let component = (try? sessionName(tag: tag).dropFirst("cmux-app-".count)).map(String.init) ?? "default"
        return support.appendingPathComponent("cmux/tags/\(component)/tui", isDirectory: true)
    }

    /// The user's per-user temp directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
    /// independent of the process's `TMPDIR`. Falls back to `/tmp`.
    public static func userTemporaryDirectory() -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
            }
        }
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
    }

    // MARK: - Ensure

    /// Environment for `server ensure`: the provider's, plus the state
    /// directory, config file and a fixed runtime base.
    func ensureEnvironment() async -> [String: String] {
        var environment = await environmentProvider()
        if let stateDirectory = configuration.stateDirectory { environment["CMUX_TUI_STATE_DIR"] = stateDirectory.path }
        if let configFile = configuration.configFile { environment["CMUX_TUI_CONFIG"] = configFile.path }
        // XDG_RUNTIME_DIR would win over TMPDIR in cmux-tui's socket lookup.
        environment["XDG_RUNTIME_DIR"] = nil
        environment["TMPDIR"] = configuration.runtimeBase.path
        return environment
    }

    /// Returns the live endpoint: a running owner from `server status`
    /// (no login environment needed, about 50 ms), else `server ensure`,
    /// which spawns one with the provider's environment. The app's provider
    /// (`appEnvironment`) never waits for the login shell.
    public func ensure() async throws -> EnsureResult {
        if let stateDirectory = configuration.stateDirectory {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        if let running = await runningOwner() { return running }
        let environment = await ensureEnvironment()
        DaemonLaunchTimings.shared.mark("daemon.ensure_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.ensure_end") }
        let result = try await ProcessRunner.run(
            executable: configuration.binary,
            arguments: Self.ensureArguments(configuration),
            environment: environment,
            timeout: ensureTimeout,
            clock: clock
        )
        return try Self.parseEnsure(result)
    }

    /// The `server ensure` command line for `configuration`.
    static func ensureArguments(_ configuration: Configuration) -> [String] {
        ["--session", configuration.session, "--json", "server", "ensure",
         "--terminal-reap-grace-seconds", String(configuration.terminalReapGraceSeconds)]
    }

    /// `server status`: the running owner, or nil when none runs (or the
    /// probe fails; `server ensure` then decides). It needs only the socket
    /// location (`TMPDIR`) and the state directory, never the login env.
    func runningOwner() async -> EnsureResult? {
        var environment = ProcessInfo.processInfo.environment
        if let stateDirectory = configuration.stateDirectory { environment["CMUX_TUI_STATE_DIR"] = stateDirectory.path }
        if let configFile = configuration.configFile { environment["CMUX_TUI_CONFIG"] = configFile.path }
        environment["XDG_RUNTIME_DIR"] = nil
        environment["TMPDIR"] = configuration.runtimeBase.path
        DaemonLaunchTimings.shared.mark("daemon.status_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.status_end") }
        guard let result = try? await ProcessRunner.run(
            executable: configuration.binary,
            arguments: ["--session", configuration.session, "--json", "server", "status"],
            environment: environment,
            timeout: ensureTimeout,
            clock: clock
        ), let parsed = try? Self.parseEnsure(result), parsed.status == "running" else { return nil }
        return parsed
    }

    /// Starts capturing the login environment now, so the first terminals
    /// have it as early as possible and the next launch remembers it. Call
    /// at the top of `main`; the capture runs off the main thread.
    public static func prewarmLoginEnvironment() {
        // task-owner: one-shot fill of the process-lifetime login-env cache; ends with the capture's own timeout.
        Task.detached(priority: .userInitiated) { await LoginEnvironmentCache.shared.start() }
    }

    static func parseEnsure(_ result: ProcessResult) throws -> EnsureResult {
        // The JSON object is the last non-empty stdout line.
        let lines = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") }
        guard result.status == 0, let last = lines.last,
              let parsed = try? JSONDecoder().decode(EnsureResult.self, from: Data(last.utf8)) else {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaemonError.launchFailed("exit \(result.status): \(stderr.isEmpty ? stdout : stderr)")
        }
        return parsed
    }

    /// Endpoint provider for `DaemonConnection`: every (re)connect re-runs
    /// `ensure`, which restarts a crashed daemon.
    public var endpointProvider: DaemonConnection.EndpointProvider {
        let remembered = rememberedSocket
        let handoff = handoff
        let clock = clock
        return {
            // A daemon exiting for a version handoff still answers `server
            // status` for a moment: start its successor only once it is gone.
            if let exiting = handoff.takeExiting() {
                _ = await ProcessExit.exitEvent(pid: exiting, within: .seconds(60), clock: clock)
            }
            if let path = remembered.take() {
                if DaemonSocketMemory.acceptsConnections(path) {
                    DaemonLaunchTimings.shared.mark("daemon.remembered_socket")
                    return DaemonEndpoint(socketPath: path)
                }
            }
            return try await ensure().endpoint
        }
    }

    /// Build commit of the bundled binary (`cmux 0.1.0 (<commit>; ghostty …)`).
    public func bundledBuildCommit() async throws -> String? {
        let result = try await ProcessRunner.run(executable: configuration.binary, arguments: ["--version"],
                                                 environment: nil, timeout: .seconds(5), clock: clock)
        return Self.parseBuildCommit(String(decoding: result.stdout, as: UTF8.self))
    }

    static func parseBuildCommit(_ version: String) -> String? {
        guard let open = version.firstIndex(of: "(") else { return nil }
        let rest = version[version.index(after: open)...]
        let commit = rest.prefix { $0.isHexDigit }
        return commit.count >= 7 ? String(commit) : nil
    }

    /// True when the running daemon was built from a different commit than
    /// the bundled binary, so the app should hand off with `restartDaemon`.
    public func isStale(_ identity: DaemonIdentity) async -> Bool {
        guard let running = identity.buildCommit, let bundled = try? await bundledBuildCommit() else { return false }
        return running != bundled
    }

    /// Asks the running owner to exit (version handoff), then ensures a new
    /// one from this binary. PTY hosts survive and are adopted.
    public func restartDaemon(identity: DaemonIdentity, using connection: DaemonConnection) async throws -> EnsureResult {
        _ = try await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation))
        return try await ensure()
    }
}

/// A remembered socket path that is handed out once.
final class RememberedSocket: Sendable {
    private let path: Mutex<String?>
    init(_ path: String?) { self.path = Mutex(path) }
    func take() -> String? { path.withLock { $0.take() } }
}
