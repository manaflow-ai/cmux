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
    /// Non-secret Computer Use launch configuration for this daemon. The v2
    /// endpoint directory is allowed; legacy socket tokens are withheld.
    public var computerUse: [String: String] = [:]
    /// Whether the daemon this app spawns gets ``offerToolsKey`` (`1`): its local sessions then get
    /// the cmux-sessions MCP server (`offer_session`), whatever the harness. On while suggested tasks
    /// are on (``AgentPaneSuggestedTasks``); ``AcpmuxHost`` reads it at each daemon start, so a running
    /// daemon keeps the value it started with.
    public var offersSessionTools = false
    /// Whether the daemon this app spawns keeps the agent message runaway guard on (acpmux
    /// `hub/agent_pairs.rs`); off, it gets ``agentPairGuardKey`` `0`. The Debug Settings toggle
    /// `agent.pairGuard`, read at each daemon start like ``offersSessionTools``.
    public var agentPairGuard = true
    /// The guard's cap and its window in seconds (`agent.pairCap`, `agent.pairWindow`); `0` turns
    /// the cap off. Passed as ``agentPairCapKey`` and ``agentPairWindowKey`` while the guard is on.
    public var agentPairCap = 20
    public var agentPairWindowSeconds = 600
    /// Whether an unsigned development daemon needs its person key on an
    /// inherited descriptor. Signed builds enroll only after checking the peer.
    public var passesPersonKeyAtSpawn = true
    /// The daemon is another app's, reached through `CMUX_NEXT_ACPMUX_ATTACH`
    /// (AcpmuxEnvironment+Attach.swift): this app never starts, hands off or ends it.
    public var isAttached = false
    /// This build's own home while attached (``logPath``); nil otherwise.
    public var ownHome: URL?

    /// The Computer Use variables (AgentActivitySocketSource.Configuration).
    /// The spawn environment drops all three when inherited and takes only
    /// the first two from `computerUse`: the host token never leaves the app.
    public static let computerUseKeys = ["CMUX_NEXT_CUA_SOCKET", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"]
    public static let computerUseHostKey = "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN"
    /// acpmux `agent_tools::OFFER_TOOLS_ENV`: `1` gives sessions `offer_session`.
    public static let offerToolsKey = "ACPMUX_OFFER_TOOLS"
    /// acpmux `hub::agent_pairs::GUARD_ENV`: `0` turns the agent message runaway guard off.
    public static let agentPairGuardKey = "ACPMUX_AGENT_PAIR_GUARD"
    /// acpmux `config::chief_builtins::CHIEF_MUX_HOME_ENV`: the Chief home whose built-in presets
    /// this daemon fills, in the daemon's own environment (NIGHTLY's app daemon runs its Chief).
    public static let chiefMuxHomeKey = "ACPMUX_CHIEF_MUX_HOME"
    /// acpmux `hub::agent_pairs::MAX_MESSAGES_ENV` and `WINDOW_ENV`.
    public static let agentPairCapKey = "ACPMUX_AGENT_PAIR_MAX_MESSAGES"
    public static let agentPairWindowKey = "ACPMUX_AGENT_PAIR_WINDOW_SECS"

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

    /// Where this app writes why it could not reach the daemon: its own home's `daemon.log`, so an
    /// attached daemon's log (another app's home) gets no line from this app.
    public var logPath: String { (ownHome ?? home).appendingPathComponent("daemon.log").path }

    /// `~/.acpmux` of `userHome`: NIGHTLY's home, and the root of every build home.
    static func sharedRoot(userHome: URL) -> URL {
        userHome.appendingPathComponent(".acpmux", isDirectory: true)
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
