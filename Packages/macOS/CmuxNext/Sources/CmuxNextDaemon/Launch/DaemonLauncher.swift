public import Foundation
import os
public import CmuxNextCompat
public import CmuxNextWakeups

/// Locates the bundled cmux-tui binary and runs `cmux-tui --session <S>
/// --json server ensure`, which returns a running owner or spawns a detached
/// (`setsid`) one that survives app quit.
///
/// Isolation: one session and `CMUX_TUI_STATE_DIR` per build
/// (``BuildIdentity/appSession``, per-build isolation S3): release keeps `cmux-app`
/// and cmux-tui's default root, a channel or reload.sh DEV build keeps
/// `cmux-app-<channel or tag>`, every other build (the untagged DEV build too)
/// has `cmux-app--<key hash>`. `run_ensure` does not
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
        /// The app's install key (P8 3b-2): handed on stdin to an owner that
        /// `ensure` spawns, and proved by `client-hello` on each connection.
        public var installKey: FrontendInstallKey?
        /// True when `binary` is the app bundle's own `bin/cmux-tui`, built from this tree. That build always accepts
        /// `--terminal-reap-grace-seconds` (since c40e1186701d), so the launcher passes it without the `--help` probe,
        /// which can time out on a loaded machine and start an owner that never reaps. An external binary
        /// (`CMUX_NEXT_TUI_BIN`) is still probed, and never gets `webSocketPageOrigins` (``pageListenerArguments(_:)``).
        public var binaryIsBundled: Bool
        public var webSocketPageOrigins: [String] // the page origins the owner's loopback WebSocket admits; empty: no listener

        public init(binary: URL, session: String, stateDirectory: URL? = nil, configFile: URL? = nil,
                    runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(),
                    terminalReapGraceSeconds: UInt32 = 30, rememberedSocket: String? = nil,
                    installKey: FrontendInstallKey? = nil, binaryIsBundled: Bool = false, webSocketPageOrigins: [String] = []) {
            self.binary = binary
            self.binaryIsBundled = binaryIsBundled
            self.webSocketPageOrigins = webSocketPageOrigins
            self.session = session
            self.stateDirectory = stateDirectory
            self.configFile = configFile
            self.runtimeBase = runtimeBase
            self.terminalReapGraceSeconds = terminalReapGraceSeconds
            self.rememberedSocket = rememberedSocket
            self.installKey = installKey
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

    /// `server ensure --json` error output on stderr.
    struct EnsureFailure: Decodable {
        var code: String
        var message: String?
    }

    /// Environment variable that overrides the bundled binary (dev builds).
    public static let binaryOverrideKey = "CMUX_NEXT_TUI_BIN"

    public let configuration: Configuration
    /// The app's one ``BackgroundWork``: `ensure`'s state-directory create runs on its files lane, never on
    /// the caller's thread (the launch's first connect and every reconnect await `ensure`).
    public let work: BackgroundWork
    /// `configuration.rememberedSocket` until the first endpoint request of
    /// any provider of this launcher takes it: the startup loop's retries
    /// and every reconnect then ask the owner (`ensure`), so a hung daemon
    /// behind a live socket cannot keep a retry loop away from `ensure`.
    private let rememberedSocket: RememberedSocket
    /// Version handoff state (`handOffIfStale`).
    let handoff = DaemonHandoffState()
    /// How the last endpoint `ensure` ended: the gate of Restart cmux-tui (DaemonLauncher+Replace).
    public let ensureOutcome = EnsureOutcome()
    let clock: any Clock<Duration>
    private let ensureTimeout: Duration
    /// Hard cap on one `server ensure`. The daemon bounds a restore itself
    /// (2 minutes, then `server.restore_timeout`), so this only has to be
    /// longer than that bound plus the time to reach the owner.
    static let ensureRestoreCap: Duration = .seconds(150)
    private let environmentProvider: @Sendable () async -> [String: String]
    /// Put on every endpoint this launcher hands out (``DaemonEndpoint/wireStats``), so the
    /// connections to its daemon count there; its socket probe counts there too. Nil counts nothing.
    public let wireStats: DaemonWireStats?

    public init(
        work: BackgroundWork,
        configuration: Configuration,
        environment: @escaping @Sendable () async -> [String: String],
        ensureTimeout: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock(),
        wireStats: DaemonWireStats? = nil
    ) {
        self.work = work
        self.configuration = configuration
        self.wireStats = wireStats
        rememberedSocket = RememberedSocket(configuration.rememberedSocket)
        self.environmentProvider = environment
        self.ensureTimeout = ensureTimeout
        self.clock = clock
    }

    /// The standard app launcher: bundled binary, session and state of the app's own
    /// build (``appNames(build:applicationSupport:)``; never an inherited `CMUX_TAG`), login-shell environment captured
    /// once per launch and remembered for the next (`LoginEnvironmentCache`). `terminalEnvironment` (the app's `CMUX_SOCKET_PATH`,
    /// `CMUX_BUNDLE_ID`, `CMUX_TAG`) and the bundled `cmux` (`<Resources>/bin` first) reach every shell it spawns;
    /// `daemonEnvironment` joins only `server ensure`; every cmux-tui process takes `CMUX_APPS_FIRST_PARTY_DIR` out of its
    /// environment at startup and honors it only inside its own app bundle, so no child inherits it (bead cx-e0cs).
    /// `resolvedTerminalEnvironment` adds the keys the app looks up on the disk off the main thread (Ghostty's `TERM`
    /// and resources), awaited when `server ensure` builds its environment, over `terminalEnvironment`.
    /// `team` is this process's Team ID (``CodeSigningTeam``), read by the caller off the main thread: an
    /// unsigned build (nil) proves itself with a `FrontendInstallKey`.
    public static func forApp(
        work: BackgroundWork,
        build: BuildIdentity,
        team: String?,
        terminalEnvironment: [String: String],
        resolvedTerminalEnvironment: (@Sendable () async -> [String: String])? = nil,
        daemonEnvironment: [String: String] = [:], webSocketPageOrigins: [String] = [],
        bundle: Bundle = .main,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        socketMemory: DaemonSocketMemory = DaemonSocketMemory(),
        applicationSupport: URL = DaemonLauncher.applicationSupportDirectory(),
        wireStats: DaemonWireStats? = nil
    ) throws -> DaemonLauncher {
        let binary = try resolveBinary(bundle: bundle, environment: processEnvironment)
        DaemonLaunchTimings.shared.mark("daemon.binary_resolved")
        let (session, stateDirectory) = appNames(build: build, applicationSupport: applicationSupport, log: true)
        let keyStore = FrontendInstallKeyStores.forApp(stateDirectory: stateDirectory, team: team)
        let configuration = Configuration(binary: binary, session: session, stateDirectory: stateDirectory,
                                          rememberedSocket: socketMemory.socket(session: session),
                                          installKey: keyStore?.loadOrCreate(),
                                          binaryIsBundled: isBundledBinary(binary, bundle: bundle), webSocketPageOrigins: webSocketPageOrigins)
        var overrides = terminalEnvironment
        if let stateDirectory { overrides["CMUX_TUI_STATE_DIR"] = stateDirectory.path }
        // A terminal the daemon starts with no caller env gets this env; its
        // shell integration keeps the bundled `cmux` first (cmux-tui `cli_path`).
        let cli = bundle.resourceURL.map { BundledCLIEnvironment(binDirectory: $0.path + "/bin", pathIntegration: nil) }
        let environment = appEnvironment(cache: .shared, base: processEnvironment, overrides: overrides,
                                         resolved: resolvedTerminalEnvironment, cli: cli)
        return DaemonLauncher(work: work, configuration: configuration, environment: { await environment().merging(daemonEnvironment) { _, owner in owner } },
                              wireStats: wireStats)
    }

    /// The launcher of a Chief home's conversation owner
    /// (plans/cmux-next/home-state-ownership.md): session `session` with its
    /// state in `stateDirectory`, shared by every build of one account. It
    /// spawns no terminals, so `server ensure` gets the process environment
    /// without any app or terminal identity, and it is never handed off to a
    /// connecting build's binary.
    public static func forChief(
        work: BackgroundWork,
        session: String,
        stateDirectory: URL,
        bundle: Bundle = .main,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DaemonLauncher {
        let binary = try resolveBinary(bundle: bundle, environment: processEnvironment)
        // An unsigned (DEV) build proves it is the app to an owner it started with this home's
        // install key, as with its own daemon: the owner then takes its origin.confirmation.issue
        // (a Home page's Chief create on the person's gesture). A signed build proves it by its
        // code signature and gets no key.
        let installKey = FrontendInstallKeyStores.forApp(stateDirectory: stateDirectory)?.loadOrCreate()
        let configuration = Configuration(binary: binary, session: session, stateDirectory: stateDirectory,
                                          installKey: installKey, binaryIsBundled: isBundledBinary(binary, bundle: bundle))
        let environment = chiefEnvironment(processEnvironment)
        return DaemonLauncher(work: work, configuration: configuration, environment: { environment })
    }

    /// The Chief owner's `server ensure` environment: the user's basic
    /// variables only, never a build's `CMUX_*` identity; the brain's tools socket (chief.*) and
    /// what the owner needs to run the other Chiefs' brains (`CMUX_TUI_CHIEF_BRAINS`); the app's pid
    /// (`CMUX_TUI_OWNER_APP_PID`), after whose exit an owner nothing needs stops.
    static func chiefEnvironment(_ base: [String: String]) -> [String: String] {
        let kept = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "SHELL", "CMUX_TUI_CHIEF_TOOLS_SOCKET",
                    "CMUX_TUI_CHIEF_BRAINS", "CMUX_TUI_OWNER_APP_PID"]
        return base.filter { kept.contains($0.key) }
    }

    /// The app launcher's `server ensure` environment: the login
    /// environment `cache` has now (`LoginEnvironmentCache.immediate()`:
    /// this launch's capture, else the one remembered from the last launch,
    /// else the app's own, and only then the capture starts at once), filtered, plus the app's identity keys and
    /// `overrides` and the `resolved` ones over them, then `cli` (the bundled `cmux` first on `PATH`). It
    /// never waits for `$SHELL -l -i`, which takes 5-17 s on some setups;
    /// the app's terminals do not depend on it, because each carries its
    /// own login `env` (`TerminalEnvironment.shared`).
    static func appEnvironment(
        cache: LoginEnvironmentCache,
        base: [String: String],
        overrides: [String: String],
        resolved: (@Sendable () async -> [String: String])? = nil,
        cli: BundledCLIEnvironment? = nil
    ) -> @Sendable () async -> [String: String] {
        {
            DaemonLaunchTimings.shared.mark("daemon.login_env_start")
            let login = await cache.immediate()
            DaemonLaunchTimings.shared.mark("daemon.login_env_end")
            let late = await resolved?() ?? [:]
            let environment = LoginEnvironment.shared.daemonEnvironment(login: login, base: base,
                                                                        overrides: overrides.merging(late) { _, resolved in resolved })
            return cli?.apply(to: environment) ?? environment
        }
    }

    // MARK: - Resolution

    /// `CMUX_NEXT_TUI_BIN`, then `Contents/Resources/bin/cmux-tui`.
    public static func resolveBinary(bundle: Bundle, environment: [String: String]) throws -> URL {
        var searched: [String] = []
        if let override = environment[binaryOverrideKey], !override.isEmpty {
            searched.append(override)
            if FileManager.checked.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        }
        if let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent("bin/cmux-tui")
            searched.append(bundled.path)
            if FileManager.checked.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        throw DaemonError.binaryNotFound(searched: searched)
    }

    /// True when `binary` is `bundle`'s `Contents/Resources/bin/cmux-tui`.
    static func isBundledBinary(_ binary: URL, bundle: Bundle) -> Bool {
        guard let resources = bundle.resourceURL else { return false }
        let bundled = resources.appendingPathComponent("bin/cmux-tui")
        return binary.standardizedFileURL.resolvingSymlinksInPath().path
            == bundled.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The untagged channel builds (bundle id to channel), each with its own
    /// daemon session and state. Mirrors `ControlSocketPath.channelBundleIDs`
    /// and cmux-tui's `app_identity.rs` `CHANNELS`. Release
    /// (`com.cmuxterm.app`) is not here: it keeps `cmux-app`.
    public static let channelBundleIDs = [
        ("com.cmuxterm.app.nightly", "nightly"),
        ("com.cmuxterm.app.rc", "rc"),
        ("com.cmuxterm.app.staging", "staging"),
    ]

    /// `cmux-app`, or `cmux-app-<tag>` with the tag reduced to a safe single
    /// path component (a kept name, ``BuildIdentity/appSession``).
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
        tagStateDirectory(tag: tag, applicationSupport: applicationSupportDirectory())
    }

    /// `<applicationSupport>/cmux/tags/<tag>/tui`.
    public static func tagStateDirectory(tag: String, applicationSupport: URL) -> URL {
        let component = (try? sessionName(tag: tag).dropFirst("cmux-app-".count)).map(String.init) ?? "default"
        return applicationSupport.appendingPathComponent("cmux/tags/\(component)/tui", isDirectory: true)
    }

    /// The user's `~/Library/Application Support`.
    public static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// The user's per-user temp directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
    /// independent of the process's `TMPDIR`. Falls back to `/tmp`.
    public static func userTemporaryDirectory() -> URL {
        // SAFETY: with a nil buffer and length 0, confstr only returns the size it needs.
        let length = unsafe confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            // SAFETY: confstr writes at most `length` bytes, the array's size, into its storage, lent for the call.
            if unsafe confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
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
            try await work.run(.userBlocking, mayBlock: .files) {
                try FileManager.checked.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
        if let running = await runningOwner() { return running }
        // The probe runs while the environment is gathered.
        async let reapGrace = supportsReapGrace()
        let environment = await ensureEnvironment()
        // The bundled binary reports restore progress (`--restore-progress`): the app
        // then waits while the owner restores and gives up only when the
        // progress stops for `ensureTimeout` (cx-n3bs). An external binary
        // may lack the option; the daemon's own restore bound ends it.
        let progress = configuration.binaryIsBundled
        let arguments = Self.ensureArguments(configuration, reapGrace: await reapGrace, progress: progress)
        DaemonLaunchTimings.shared.mark("daemon.ensure_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.ensure_end") }
        let result = try await ProcessRunner.run(
            executable: configuration.binary,
            arguments: arguments,
            environment: environment,
            stdin: configuration.installKey?.payload,
            timeout: progress ? Self.ensureRestoreCap : max(ensureTimeout, Self.ensureRestoreCap),
            progressIdle: progress ? ensureTimeout : nil,
            clock: clock
        )
        return try Self.parseEnsure(result)
    }

    /// The `server ensure` command line for `configuration`. `reapGrace`
    /// says whether the binary accepts `--terminal-reap-grace-seconds`
    /// (``supportsReapGrace()``); a client without it refuses the option.
    static func ensureArguments(_ configuration: Configuration, reapGrace: Bool = true,
                                progress: Bool = false) -> [String] {
        ["--session", configuration.session, "--json", "server", "ensure"]
            + (reapGrace ? ["--terminal-reap-grace-seconds", String(configuration.terminalReapGraceSeconds)] : [])
            + (configuration.installKey == nil ? [] : ["--install-key-stdin"])
            + (progress ? ["--restore-progress"] : []) + pageListenerArguments(configuration)
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

    static func parseEnsure(_ result: ProcessResult) throws -> EnsureResult {
        // The JSON object is the last non-empty stdout line.
        let lines = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") }
        guard result.status == 0, let last = lines.last,
              let parsed = try? JSONDecoder().decode(EnsureResult.self, from: Data(last.utf8)) else {
            // The owner is alive but still restoring after the daemon's own
            // bound: a typed error, so the window says so plainly.
            let errorLine = String(decoding: result.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
            if let errorLine,
               let failure = try? JSONDecoder().decode(EnsureFailure.self, from: Data(errorLine.utf8)),
               failure.code == "server.restore_timeout" {
                throw DaemonError.sessionRestoreTimedOut(failure.message ?? "")
            }
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaemonError.launchFailed("exit \(result.status): \(stderr.isEmpty ? stdout : stderr)")
        }
        return parsed
    }

    /// Endpoint provider for `DaemonConnection`: every (re)connect re-runs
    /// `ensure`, which restarts a crashed daemon.
    public var endpointProvider: DaemonConnection.EndpointProvider { spawnObservingEndpointProvider(onSpawned: nil) }

    /// ``endpointProvider`` that also calls `onSpawned` after each `ensure` that started a daemon (status
    /// `started`, never a running owner or a remembered socket): the launch's `daemon.spawned` milestone.
    public func spawnObservingEndpointProvider(onSpawned: (@Sendable () -> Void)?) -> DaemonConnection.EndpointProvider {
        let remembered = rememberedSocket
        let handoff = handoff
        let clock = clock
        let wireStats = wireStats
        return {
            // A daemon exiting for a version handoff still answers `server
            // status` for a moment: start its successor only once it is gone.
            if let exiting = handoff.exiting {
                _ = await ProcessExit.exitEvent(pid: exiting, within: .seconds(60), clock: clock)
                handoff.cancel(pid: exiting)
            }
            if let path = remembered.take() {
                if DaemonSocketMemory.acceptsConnections(path, wireStats: wireStats) {
                    DaemonLaunchTimings.shared.mark("daemon.remembered_socket")
                    return DaemonEndpoint(socketPath: path, wireStats: wireStats)
                }
            }
            let ensured = try await ensureRecordingOutcome()
            if ensured.status == "started" { onSpawned?() }
            var endpoint = ensured.endpoint
            endpoint.wireStats = wireStats
            return endpoint
        }
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
