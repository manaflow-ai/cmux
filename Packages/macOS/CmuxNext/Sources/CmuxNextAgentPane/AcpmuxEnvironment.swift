public import CmuxNextCompat
public import Foundation

/// Where this app's acpmux daemon lives and how to start it.
///
/// Same rule as `cmux acp` (cmux-tui `acp::build_home`), so the pane and
/// the CLI in its terminals reach one daemon: `ACPMUX_HOME` wins, else the
/// build's own home (``BuildIdentity/acpmuxHome(userHome:)``, per-build
/// isolation cx-is1kf): NIGHTLY keeps `~/.acpmux`, shared with a standalone
/// `acpmux`; every other build has `~/.acpmux/builds/<key>`, so no build
/// starts, stops or hands off another build's daemon. A daemon in a home of
/// its own listens on an ephemeral port, never the shared daemon's 47811.
/// `ACPMUX_SOCKET` counts only with an explicit `ACPMUX_HOME`: inherited
/// alone (an app launched from another cmux's terminal), it is another
/// daemon's socket.
public nonisolated struct AcpmuxEnvironment: Sendable, Equatable {
    public var executable: URL
    public var home: URL
    public var socketPath: String
    /// Extra `acpmux daemon run` arguments.
    public var daemonArguments: [String]
    /// Variables the daemon and the status client must agree on.
    public var childEnvironment: [String: String]
    /// The Computer Use socket and agent token (`computerUseKeys`) for the
    /// daemon this app spawns, so its agents reach the app's Computer Use
    /// helper; empty while Computer Use is off. Only the spawn environment
    /// carries them: the app never writes its own process environment.
    public var computerUse: [String: String] = [:]
    /// Whether the daemon this app spawns gets ``offerToolsKey`` (`1`): its local sessions then get
    /// the cmux-sessions MCP server (`offer_session`), whatever the harness. On while the Debug
    /// Settings toggle `agent.suggestedTasks` is on; ``AcpmuxHost`` reads it at each daemon start, so a running
    /// daemon keeps the value it started with.
    public var offersSessionTools = false
    /// Whether an unsigned development daemon needs its person key on an
    /// inherited descriptor. Signed builds enroll only after checking the peer.
    public var passesPersonKeyAtSpawn = true

    /// The Computer Use variables (AgentActivitySocketSource.Configuration).
    /// The spawn environment drops all three when inherited and takes only
    /// the first two from `computerUse`: the host token never leaves the app.
    public static let computerUseKeys = ["CMUX_NEXT_CUA_SOCKET", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"]
    public static let computerUseHostKey = "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN"
    /// acpmux `agent_tools::OFFER_TOOLS_ENV`: `1` gives sessions `offer_session`.
    public static let offerToolsKey = "ACPMUX_OFFER_TOOLS"

    /// The build-session kill switch (cx-9ettq): with either set, acpmux
    /// starts no agent and the Chief host does not start. A GUI test job sets
    /// one on the app; `childEnvironment` passes it to every acpmux daemon,
    /// router and Chief host the app starts.
    public static let agentLaunchKeys = ["ACPMUX_AGENT_LAUNCH", "CMUX_AGENTS_DISABLED"]

    /// Whether `environment` turns agent launches off (`ACPMUX_AGENT_LAUNCH=deny`
    /// or `CMUX_AGENTS_DISABLED=1`, the same test as acpmux's launch_policy.rs).
    public static func agentLaunchDisabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let launch = environment["ACPMUX_AGENT_LAUNCH"]?.trimmingCharacters(in: .whitespaces).lowercased()
        let disabled = environment["CMUX_AGENTS_DISABLED"]?.trimmingCharacters(in: .whitespaces)
        return launch == "deny" || disabled == "1"
    }

    public var logPath: String { home.appendingPathComponent("daemon.log").path }

    /// Resolves the environment of `build` (nil: no build, the shared home),
    /// or nil when no `acpmux` executable exists. `bundledBinDirectory` is the
    /// app's `Contents/Resources/bin`. A Debug compile takes a test root for
    /// `~/.acpmux` from `CMUX_NEXT_ACPMUX_ROOT` (tests only).
    public static func resolve(
        build: BuildIdentity?,
        bundledBinDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        launchEnvironment: [String: String] = [:]
    ) -> AcpmuxEnvironment? {
        // DEBUG only: `CMUX_NEXT_ACPMUX_BIN` wins (AcpmuxEnvironment+DebugOverride.swift).
        // Release passes nil, so it compiles no read of it.
        #if DEBUG
        let executableOverride = debugExecutableOverride
        #else
        let executableOverride: URL? = nil
        #endif
        return resolve(build: build, bundledBinDirectory: bundledBinDirectory, environment: environment, userHome: userHome,
                       uid: uid, isExecutable: isExecutable, launchEnvironment: launchEnvironment,
                       executableOverride: executableOverride)
    }

    /// ``resolve(build:bundledBinDirectory:environment:userHome:uid:isExecutable:launchEnvironment:)`` with
    /// the executable override given: tests pass nil, so a developer's exported
    /// `CMUX_NEXT_ACPMUX_BIN` cannot change what they resolve.
    static func resolve(
        build: BuildIdentity?,
        bundledBinDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        launchEnvironment: [String: String] = [:],
        executableOverride: URL?
    ) -> AcpmuxEnvironment? {
        guard let executable = executableOverride
            ?? executableCandidates(bundledBinDirectory: bundledBinDirectory, environment: environment, userHome: userHome)
            .first(where: { isExecutable($0.path) }) else { return nil }
        let root = testRoot(environment) ?? userHome.appendingPathComponent(".acpmux", isDirectory: true)
        let ownHome = build?.acpmuxHome(root: root) ?? root
        let home: URL
        let customHome = environment["ACPMUX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        if let customHome {
            home = URL(fileURLWithPath: customHome, isDirectory: true)
        } else {
            home = ownHome
        }
        let configured = customHome == nil ? nil : environment["ACPMUX_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        let socket = socketPath(configured: configured, home: home, uid: uid)
        var childEnvironment = ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket, "ACPMUX_LOCAL_ROUTER": "1",
                                "ACPMUX_SECRET_TOOLS": "1"]
        childEnvironment.merge(launchEnvironment) { _, new in new }
        for key in agentLaunchKeys {
            if let value = environment[key], !value.isEmpty { childEnvironment[key] = value }
        }
        if let cli = bundledBinDirectory?.appendingPathComponent("cmux").path, isExecutable(cli) {
            childEnvironment["CMUX_BUNDLED_CLI_PATH"] = cli
        }
        return AcpmuxEnvironment(
            executable: executable, home: home, socketPath: socket,
            daemonArguments: ownHome == root ? [] : ["--listen", "127.0.0.1:0"], childEnvironment: childEnvironment
        )
    }

    /// `CMUX_NEXT_ACPMUX_ROOT`, the directory that stands for `~/.acpmux` in a
    /// Debug compile (live per-build tests); nil in Release.
    static func testRoot(_ environment: [String: String]) -> URL? {
        #if DEBUG
        guard let root = environment["CMUX_NEXT_ACPMUX_ROOT"], !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        #else
        return nil
        #endif
    }

    /// The usual install directories, searched after `PATH`. The pane names
    /// them when acpmux is missing, so they are written as a user types them.
    static let installDirectories = ["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Search order: the bundled binary, then `PATH`, then the usual install
    /// directories an app launched from Finder does not have on its `PATH`.
    static func executableCandidates(bundledBinDirectory: URL?, environment: [String: String], userHome: URL) -> [URL] {
        var directories: [String] = []
        if let bundled = bundledBinDirectory { directories.append(bundled.path) }
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += installDirectories.map { directory in
            directory.hasPrefix("~/") ? userHome.appendingPathComponent(String(directory.dropFirst(2))).path : directory
        }
        var seen: Set<String> = []
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("acpmux") }
    }

    /// Mirrors acpmux `config::socket_path()`: `<home>/acpmux.sock`, or
    /// `/tmp/acpmux-<uid>/<fnv1a64(home)>.sock` (a private 0700 directory)
    /// when that is too long for `sun_path` (96 bytes or more).
    /// The longest Unix socket path every host binds (cmux-agent-pane-policy
    /// `MAX_SOCKET_PATH_BYTES`): macOS's `sun_path` less its NUL.
    static let maxSocketPathBytes = 103

    /// The acpmux daemon socket every host and client resolves (cmux-agent-pane-policy
    /// `environment::socket_path`, tests/cases/environment.json): `configured`
    /// (`ACPMUX_SOCKET`) when set, except an absolute path past the Unix socket limit (a long
    /// TMPDIR), which maps to the short alias acpmux binds; else ``defaultSocketPath(home:uid:)``.
    static func socketPath(configured: String?, home: URL, uid: UInt32) -> String {
        guard let configured else { return defaultSocketPath(home: home, uid: uid) }
        if configured.hasPrefix("/"), configured.utf8.count > maxSocketPathBytes {
            return shortAlias(configured, uid: uid)
        }
        return configured
    }

    /// `/tmp/acpmux-<uid>/<fnv1a64(key)>.sock`.
    static func shortAlias(_ key: String, uid: UInt32) -> String {
        "/tmp/acpmux-\(uid)/\(String(format: "%016llx", fnv1a64(key))).sock"
    }

    static func defaultSocketPath(home: URL, uid: UInt32) -> String {
        let preferred = home.appendingPathComponent("acpmux.sock").path
        if preferred.utf8.count < 96 { return preferred }
        return shortAlias(home.path, uid: uid)
    }

    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

extension AcpmuxEnvironment {
    /// `_acpmux/tag`: sets and removes tags of one session (a chat's mute, cx-sg1qz).
    public nonisolated func tag(session: String, set: [String: String], remove: [String]) async throws {
        try await AcpmuxStatusClient.tag(socketPath: socketPath, sessionId: session, set: set, remove: remove)
    }
}
