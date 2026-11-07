public import Foundation
import os
public import CmuxNextCompat

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
        /// (`CMUX_NEXT_TUI_BIN`) is still probed, and never gets `webSocketPageOrigins` (`ensure_arguments`).
        public var binaryIsBundled: Bool
        public var webSocketPageOrigins: [String] // the page origins the owner's loopback WebSocket admits; empty: no listener
        /// `server ensure --exit-with-pid`: an owner `ensure` spawns ends its terminals and stops when this process
        /// exits. For test harnesses (`getpid()`), so a crashed or cancelled run leaves no owner behind; the app
        /// never sets it, because its owner outlives the app. Needs a same-tree cmux-tui (older ones refuse it).
        public var exitWithProcess: Int32?

        public init(binary: URL, session: String, stateDirectory: URL? = nil, configFile: URL? = nil,
                    runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(),
                    terminalReapGraceSeconds: UInt32 = 30, rememberedSocket: String? = nil,
                    installKey: FrontendInstallKey? = nil, binaryIsBundled: Bool = false, webSocketPageOrigins: [String] = [],
                    exitWithProcess: Int32? = nil) {
            self.binary = binary
            self.exitWithProcess = exitWithProcess
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
    /// How the last endpoint `ensure` ended: the gate of Restart cmux-tui (DaemonLauncher+Replace).
    public let ensureOutcome = EnsureOutcome()
    let clock: any Clock<Duration>
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

    /// The standard app launcher: bundled binary, session and state of the app's own
    /// build (``appNames(build:applicationSupport:)``; never an inherited `CMUX_TAG`), login-shell environment captured
    /// once per launch and remembered for the next (`LoginEnvironmentCache`). `terminalEnvironment` (the app's `CMUX_SOCKET_PATH`,
    /// `CMUX_BUNDLE_ID`, `CMUX_TAG`) and the bundled `cmux` (`<Resources>/bin` first) reach every shell it spawns;
    /// `daemonEnvironment` joins only `server ensure`; every cmux-tui process takes `CMUX_APPS_FIRST_PARTY_DIR` out of its
    /// environment at startup and honors it only inside its own app bundle, so no child inherits it (bead cx-e0cs).
    public static func forApp(
        build: BuildIdentity,
        terminalEnvironment: [String: String],
        daemonEnvironment: [String: String] = [:], webSocketPageOrigins: [String] = [],
        bundle: Bundle = .main,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        socketMemory: DaemonSocketMemory = DaemonSocketMemory(),
        applicationSupport: URL = DaemonLauncher.applicationSupportDirectory()
    ) throws -> DaemonLauncher {
        let binary = try resolveBinary(bundle: bundle, environment: processEnvironment)
        DaemonLaunchTimings.shared.mark("daemon.binary_resolved")
        let (session, stateDirectory) = appNames(build: build, applicationSupport: applicationSupport, log: true)
        let keyStore = FrontendInstallKeyStores.forApp(stateDirectory: stateDirectory)
        let configuration = Configuration(binary: binary, session: session, stateDirectory: stateDirectory,
                                          rememberedSocket: socketMemory.socket(session: session),
                                          installKey: keyStore?.loadOrCreate(),
                                          binaryIsBundled: isBundledBinary(binary, bundle: bundle), webSocketPageOrigins: webSocketPageOrigins)
        var overrides = terminalEnvironment
        if let stateDirectory { overrides["CMUX_TUI_STATE_DIR"] = stateDirectory.path }
        // A terminal the daemon starts with no caller env gets this env; its
        // shell integration keeps the bundled `cmux` first (cmux-tui `cli_path`).
        let cli = bundle.resourceURL.map { BundledCLIEnvironment(binDirectory: $0.path + "/bin", pathIntegration: nil) }
        let environment = appEnvironment(cache: .shared, base: processEnvironment, overrides: overrides, cli: cli)
        return DaemonLauncher(configuration: configuration, environment: { await environment().merging(daemonEnvironment) { _, owner in owner } })
    }

    /// The launcher of a Chief home's conversation owner
    /// (plans/cmux-next/home-state-ownership.md): session `session` with its
    /// state in `stateDirectory`, shared by every build of one account. It
    /// spawns no terminals, so `server ensure` gets the process environment
    /// without any app or terminal identity, and it is never handed off to a
    /// connecting build's binary for being another build; only once an update
    /// deleted its executable (`ChiefConversationOwner.restartIfReplaced`).
    ///
    /// `ownerEnvironment`, when given, replaces `processEnvironment` as the base of the owner's
    /// environment and runs only when `server ensure` spawns an owner, never here: the Chief's
    /// (`ChiefConversationOwner.ownerEnvironment`) checks the acpmux executable's signature, a
    /// read of the whole file that held the main thread 2.86 s at launch.
    public static func forChief(
        session: String,
        stateDirectory: URL,
        bundle: Bundle = .main,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        ownerEnvironment: (@Sendable () async -> [String: String])? = nil
    ) throws -> DaemonLauncher {
        let binary = try resolveBinary(bundle: bundle, environment: processEnvironment)
        // An unsigned (DEV) build proves it is the app to an owner it started with this home's
        // install key, as with its own daemon: the owner then takes its origin.confirmation.issue
        // (a Home page's Chief create on the person's gesture). A signed build proves it by its
        // code signature and gets no key.
        let installKey = FrontendInstallKeyStores.forApp(stateDirectory: stateDirectory)?.loadOrCreate()
        let configuration = Configuration(binary: binary, session: session, stateDirectory: stateDirectory,
                                          installKey: installKey, binaryIsBundled: isBundledBinary(binary, bundle: bundle))
        if let ownerEnvironment {
            return DaemonLauncher(configuration: configuration, environment: { chiefEnvironment(await ownerEnvironment()) })
        }
        let environment = chiefEnvironment(processEnvironment)
        return DaemonLauncher(configuration: configuration, environment: { environment })
    }

    /// The Chief owner's `server ensure` environment (cmux-daemon-launch-core `chief_environment`): the user's
    /// basic variables only, never a build's `CMUX_*` identity; the brain's tools socket (chief.*) and what the
    /// owner needs to run the other Chiefs' brains (`CMUX_TUI_CHIEF_BRAINS`); and the R-DAEMON-STATE input lane
    /// switch from the app's launch knobs, since the Chief owner follows the app daemon's rules. A library that
    /// does not answer gives the owner nothing of the base (never a build's identity).
    static func chiefEnvironment(_ base: [String: String]) -> [String: String] {
        DaemonLaunchRules.call("chief_environment", DaemonLaunchRules.Environment(environment: base), as: [String: String].self) ?? [:]
    }

    /// The app launcher's `server ensure` environment: the login
    /// environment `cache` has now (`LoginEnvironmentCache.immediate()`:
    /// this launch's capture, else the one remembered from the last launch,
    /// else the app's own), filtered, plus the app's identity keys and
    /// `overrides`, then `cli` (the bundled `cmux` first on `PATH`). It
    /// never waits for `$SHELL -l -i`, which takes 5-17 s on some setups;
    /// the app's terminals do not depend on it, because each carries its
    /// own login `env` (`TerminalEnvironment.shared`).
    static func appEnvironment(
        cache: LoginEnvironmentCache,
        base: [String: String],
        overrides: [String: String],
        cli: BundledCLIEnvironment? = nil
    ) -> @Sendable () async -> [String: String] {
        {
            DaemonLaunchTimings.shared.mark("daemon.login_env_start")
            let login = await cache.immediate()
            DaemonLaunchTimings.shared.mark("daemon.login_env_end")
            let environment = LoginEnvironment.shared.daemonEnvironment(login: login, base: base, overrides: overrides)
            return cli?.apply(to: environment) ?? environment
        }
    }

    // MARK: - Resolution

    /// `CMUX_NEXT_TUI_BIN` when executable, then `Contents/Resources/bin/cmux-tui` (cmux-daemon-launch-core
    /// `resolve_binary`, which reads the disk).
    public static func resolveBinary(bundle: Bundle, environment: [String: String]) throws -> URL {
        struct Request: Encodable { var `override`: String?, resources: String? }
        struct Reply: Decodable { var binary: String?, searched: [String]? }
        let request = Request(override: environment[binaryOverrideKey, default: ""], resources: bundle.resourceURL?.path)
        guard let reply = DaemonLaunchRules.call("resolve_binary", request, as: Reply.self) else {
            throw DaemonError.launchFailed("the daemon launch rules did not answer")
        }
        if let binary = reply.binary { return URL(fileURLWithPath: binary) }
        throw DaemonError.binaryNotFound(searched: reply.searched ?? [])
    }

    /// True when `binary` is `bundle`'s `Contents/Resources/bin/cmux-tui`.
    static func isBundledBinary(_ binary: URL, bundle: Bundle) -> Bool {
        guard let resources = bundle.resourceURL else { return false }
        let bundled = resources.appendingPathComponent("bin/cmux-tui")
        return binary.standardizedFileURL.resolvingSymlinksInPath().path
            == bundled.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The untagged channel builds (bundle id to channel), each with its own
    /// daemon session and state (cmux-daemon-launch-core `channel_bundle_ids`, cmux-tui's
    /// `app_identity.rs` `CHANNELS`; `ControlSocketPath.channelBundleIDs` mirrors it). Release
    /// (`com.cmuxterm.app`) is not here: it keeps `cmux-app`.
    public static let channelBundleIDs: [(String, String)] = {
        struct Channel: Decodable { var bundleId: String, channel: String }
        let channels = DaemonLaunchRules.call("channel_bundle_ids", [String: String](), as: [Channel].self) ?? []
        return channels.map { ($0.bundleId, $0.channel) }
    }()

    /// `cmux-app`, or `cmux-app-<tag>` with the tag reduced to a safe single
    /// path component (a kept name, ``BuildIdentity/appSession``; cmux-daemon-launch-core `session_name`).
    public static func sessionName(tag: String?) throws -> String {
        struct Request: Encodable { var tag: String? }
        guard let name = DaemonLaunchRules.call("session_name", Request(tag: tag), as: String?.self) ?? nil else {
            throw DaemonError.invalidSessionName(tag ?? "")
        }
        return name
    }

    /// The tag's daemon state directory in the user's Application Support.
    public static func tagStateDirectory(tag: String) -> URL? {
        tagStateDirectory(tag: tag, applicationSupport: applicationSupportDirectory())
    }

    /// The tag's daemon state directory under `applicationSupport` (cmux-daemon-launch-core
    /// `tag_state_directory`; an unusable tag is `default`); nil when the library does not answer.
    public static func tagStateDirectory(tag: String, applicationSupport: URL) -> URL? {
        struct Request: Encodable { var tag: String, applicationSupport: String }
        return DaemonLaunchRules.call("tag_state_directory", Request(tag: tag, applicationSupport: applicationSupport.path),
                                      as: String.self).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The user's `~/Library/Application Support`.
    public static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
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

    /// The launch rules' answer, or a launch failure when the library does not answer.
    static func rule<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw DaemonError.launchFailed("the daemon launch rules did not answer") }
        return value
    }

    /// Environment for `server ensure` (or, `forStatus`, `server status`) from `base`: plus the state
    /// directory, config file and a fixed runtime base, without `XDG_RUNTIME_DIR`
    /// (cmux-daemon-launch-core `ensure_environment`). `skipsStatus`: a NEXT Cloud runtime launch is
    /// authoritative for backend selection, so it skips the status fast path and `server ensure` can replace a
    /// daemon the previous launch left; only that ensure gets the one-shot launcher marker.
    func ensureEnvironment(base: [String: String], forStatus: Bool = false) throws -> (environment: [String: String], skipsStatus: Bool) {
        struct Request: Encodable {
            var base: [String: String], stateDirectory: String?, configFile: String?, runtimeBase: String, forStatus: Bool
        }
        struct Reply: Decodable { var environment: [String: String], skipsStatus: Bool }
        let request = Request(base: base, stateDirectory: configuration.stateDirectory?.path, configFile: configuration.configFile?.path,
                              runtimeBase: configuration.runtimeBase.path, forStatus: forStatus)
        let reply = try Self.rule(DaemonLaunchRules.call("ensure_environment", request, as: Reply.self))
        return (reply.environment, reply.skipsStatus)
    }

    /// Environment for `server ensure`: the provider's, made fit by ``ensureEnvironment(base:forStatus:)``.
    func ensureEnvironment() async throws -> (environment: [String: String], skipsStatus: Bool) {
        try ensureEnvironment(base: await environmentProvider())
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
        let (environment, skipsStatus) = try await ensureEnvironment()
        if !skipsStatus, let running = await runningOwner() { return running }
        DaemonLaunchTimings.shared.mark("daemon.ensure_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.ensure_end") }
        return try await runEnsure(environment: environment, replace: false)
    }

    /// One `server ensure` (`replace`: with `--replace-unresponsive`) and its parsed answer. The bundled binary
    /// reports restore progress (`--restore-progress`): the app then waits while the owner restores and gives
    /// up only when the progress stops (cx-n3bs); an external binary may lack the option, and the restore cap
    /// bounds it (cmux-daemon-launch-core `ensure_timing`).
    func runEnsure(environment: [String: String], replace: Bool) async throws -> EnsureResult {
        struct TimingRequest: Encodable { var binaryIsBundled: Bool, ensureTimeoutMs: UInt64, replace: Bool }
        struct Timing: Decodable { var progress: Bool, timeoutMs: UInt64, progressIdleMs: UInt64? }
        let timing = try Self.rule(DaemonLaunchRules.call(
            "ensure_timing",
            TimingRequest(binaryIsBundled: configuration.binaryIsBundled, ensureTimeoutMs: DaemonLaunchRules.milliseconds(ensureTimeout),
                          replace: replace),
            as: Timing.self))
        let arguments = try Self.ensureArguments(configuration, reapGrace: await supportsReapGrace(), progress: timing.progress,
                                                 replace: replace)
        let result = try await ProcessRunner.run(
            executable: configuration.binary,
            arguments: arguments,
            environment: environment,
            stdin: configuration.installKey?.payload,
            timeout: .milliseconds(Int64(clamping: timing.timeoutMs)),
            progressIdle: timing.progressIdleMs.map { Duration.milliseconds(Int64(clamping: $0)) },
            clock: clock
        )
        return try Self.parseEnsure(result, replace: replace)
    }

    /// The `server ensure` command line for `configuration` (cmux-daemon-launch-core `ensure_arguments`).
    /// `reapGrace` says whether the binary accepts `--terminal-reap-grace-seconds` (``supportsReapGrace()``);
    /// `replace` is "Restart cmux-tui"'s `--replace-unresponsive`.
    static func ensureArguments(_ configuration: Configuration, reapGrace: Bool = true,
                                progress: Bool = false, replace: Bool = false) throws -> [String] {
        struct Request: Encodable {
            var session: String, reapGraceSeconds: UInt32, reapGrace: Bool, installKey: Bool, exitWithPid: Int32?
            var progress: Bool, binaryIsBundled: Bool, pageOrigins: [String], replaceUnresponsive: Bool
        }
        let request = Request(session: configuration.session, reapGraceSeconds: configuration.terminalReapGraceSeconds,
                              reapGrace: reapGrace, installKey: configuration.installKey != nil,
                              exitWithPid: configuration.exitWithProcess, progress: progress,
                              binaryIsBundled: configuration.binaryIsBundled, pageOrigins: configuration.webSocketPageOrigins,
                              replaceUnresponsive: replace)
        return try rule(DaemonLaunchRules.call("ensure_arguments", request, as: [String].self))
    }

    /// `server status`: the running owner, or nil when none runs (or the
    /// probe fails; `server ensure` then decides). It needs only the socket
    /// location (`TMPDIR`) and the state directory, never the login env.
    func runningOwner() async -> EnsureResult? {
        struct Request: Encodable { var session: String }
        guard let environment = try? ensureEnvironment(base: ProcessInfo.processInfo.environment, forStatus: true).environment,
              let arguments = DaemonLaunchRules.call("status_arguments", Request(session: configuration.session), as: [String].self)
        else { return nil }
        DaemonLaunchTimings.shared.mark("daemon.status_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.status_end") }
        guard let result = try? await ProcessRunner.run(
            executable: configuration.binary,
            arguments: arguments,
            environment: environment,
            timeout: ensureTimeout,
            clock: clock
        ), let parsed = try? Self.parseEnsure(result, replace: false), parsed.status == "running" else { return nil }
        return parsed
    }

    /// Starts capturing the login environment now, so the first terminals
    /// have it as early as possible and the next launch remembers it. Call
    /// at the top of `main`; the capture runs off the main thread.
    public static func prewarmLoginEnvironment() {
        // task-owner: one-shot fill of the process-lifetime login-env cache; ends with the capture's own timeout.
        Task.detached(priority: .userInitiated) { await LoginEnvironmentCache.shared.start() }
    }

    /// Reads one ensure's result (cmux-daemon-launch-core `parse_ensure`): the last stdout line that is a JSON
    /// object on exit 0; else ``DaemonError/sessionRestoreTimedOut(_:)`` for an owner still restoring past the
    /// daemon's bound, ``ReplaceRefusal`` for a refused `replace`, or ``DaemonError/launchFailed(_:)`` with
    /// stderr (else stdout).
    static func parseEnsure(_ result: ProcessResult, replace: Bool) throws -> EnsureResult {
        struct Request: Encodable { var status: Int32, stdout: String, stderr: String, replace: Bool }
        struct Reply: Decodable {
            var ok: EnsureResult?
            var restoreTimeout: String?
            var launchFailed: String?
            var replaceRefusal: ReplaceRefusal?
        }
        let request = Request(status: result.status, stdout: String(decoding: result.stdout, as: UTF8.self),
                              stderr: String(decoding: result.stderr, as: UTF8.self), replace: replace)
        let reply = try rule(DaemonLaunchRules.call("parse_ensure", request, as: Reply.self))
        if let ok = reply.ok { return ok }
        if let refusal = reply.replaceRefusal { throw refusal }
        if let message = reply.restoreTimeout { throw DaemonError.sessionRestoreTimedOut(message) }
        throw DaemonError.launchFailed(reply.launchFailed ?? "exit \(result.status)")
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
            if let exiting = handoff.exiting {
                _ = await ProcessExit.exitEvent(pid: exiting, within: .seconds(60), clock: clock)
                handoff.cancel(pid: exiting)
            }
            if let path = remembered.take() {
                if DaemonSocketMemory.acceptsConnections(path) {
                    DaemonLaunchTimings.shared.mark("daemon.remembered_socket")
                    return DaemonEndpoint(socketPath: path)
                }
            }
            return try await ensureRecordingOutcome().endpoint
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
