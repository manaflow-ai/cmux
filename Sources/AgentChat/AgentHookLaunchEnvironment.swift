import CmuxSocketControl
import Darwin
import Foundation

/// Launch-side half of the agent conversation hook ingest
/// (docs/agent-conversation-protocol.md, "Hook ingest").
///
/// The daemon (`cmuxd-remote`) listens on a per-user ingest socket while chat
/// subscriptions are open; agent hooks push frames into it through the
/// `agent-hook-emit` verb. This type computes the two values the launch side
/// must agree on with that daemon:
///
/// - the ingest socket path for THIS cmux instance (tag-scoped for dev,
///   nightly, and staging builds so they never collide with the user's
///   stable daemon), and
/// - the staged `cmuxd-remote` binary that serves as the emit relay.
///
/// Both are handed to agent CLI launches as environment variables; the
/// bundled launch wrappers (`Resources/bin/cmux-claude-wrapper`,
/// `Resources/bin/cmux-codex-wrapper`) read them to inject per-launch hook
/// configuration. When no daemon binary is cached the variables are not set
/// and the wrappers skip injection entirely, so agent launches never depend
/// on this feature.
enum AgentHookLaunchEnvironment {
    /// Environment key carrying the ingest socket path. Honored as an
    /// override when already present in the app's own environment (matches
    /// the daemon, which reads the same key).
    static let socketEnvKey = "CMUX_AGENT_HOOK_SOCKET"
    /// Environment key carrying the absolute path of the staged
    /// `cmuxd-remote` binary used as the hook emit relay.
    static let emitBinaryEnvKey = "CMUX_AGENT_HOOK_EMIT_BIN"

    /// The ingest socket path for this cmux instance.
    ///
    /// Stable release builds use the daemon's documented default
    /// (`/tmp/cmuxd-agentconv-<uid>/ingest.sock`). Every other variant
    /// (tagged dev, untagged debug, nightly, staging) gets its own directory
    /// (`/tmp/cmuxd-agentconv-<uid>-<variant>[-<slug>]/ingest.sock`) so a
    /// tagged dev app's daemon and hooks never cross-talk with the stable
    /// app's. An explicit `CMUX_AGENT_HOOK_SOCKET` in the app's environment
    /// wins (tests and operator overrides).
    static func ingestSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = AgentHookLaunchEnvironment.isDebugBuild,
        uid: uid_t = getuid()
    ) -> String {
        if let override = environment[socketEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let base = "/tmp/cmuxd-agentconv-\(uid)"
        let directory: String
        switch SocketPathMarkerFiles.variant(bundleIdentifier: bundleIdentifier, environment: environment) {
        case .stable:
            directory = isDebugBuild ? "\(base)-debug" : base
        case .dev(let slug):
            directory = suffixed(base, variant: "debug", slug: slug)
        case .nightly(let slug):
            directory = suffixed(base, variant: "nightly", slug: slug)
        case .staging(let slug):
            directory = suffixed(base, variant: "staging", slug: slug)
        }
        return directory + "/ingest.sock"
    }

    /// The emit relay binary safe to inject into agent launches, or `nil`.
    ///
    /// The `hello` capability handshake cannot vouch for the launch side: a
    /// cached daemon predating the `agent-hook-emit` verb falls through to
    /// its CLI dispatch when invoked with it (connecting to the app control
    /// socket and exiting non-zero), which would stall or garble every
    /// Claude hook. Injection therefore requires provenance that provably
    /// carries the verb:
    ///
    /// - the explicit `CMUX_REMOTE_DAEMON_BINARY` dev override (opt-in,
    ///   assumed current), on any build;
    /// - on release builds only, a cached binary at this app's exact release
    ///   version (same-SHA release artifacts) or newer (the verb is
    ///   additive). Debug builds share marketing versions with release
    ///   artifacts built from different SHAs, so they inject only with the
    ///   override, which dev dogfood of this feature already requires.
    static func injectableEmitBinaryURL(
        outcome: AgentDaemonBinaryLocator.Outcome,
        appVersion: String = AgentDaemonBinaryLocator.appVersionString(),
        isDebugBuild: Bool = AgentHookLaunchEnvironment.isDebugBuild
    ) -> URL? {
        guard case .found(let url, let provenance) = outcome else { return nil }
        switch provenance {
        case .explicitOverride:
            return url
        case .cached(let version):
            guard !isDebugBuild else { return nil }
            if version == appVersion { return url }
            return AgentDaemonBinaryLocator.isVersionNewer(version, appVersion) ? url : nil
        }
    }

    /// The environment pairs a terminal surface (or any agent launch) needs
    /// for hook injection, or `nil` when no staged daemon binary exists.
    /// Skipping entirely when the binary is missing keeps agent launches
    /// independent of this feature: the wrappers only inject when both keys
    /// are present and the emit binary is executable.
    static func launchEnvironment(
        emitBinaryURL: URL?,
        socketPath: String
    ) -> [(key: String, value: String)]? {
        guard let emitBinaryURL else { return nil }
        let path = emitBinaryURL.standardizedFileURL.path
        guard !path.isEmpty, !socketPath.isEmpty else { return nil }
        return [
            (emitBinaryEnvKey, path),
            (socketEnvKey, socketPath),
        ]
    }

    /// The environment for the locally spawned `cmuxd-remote serve --stdio`
    /// child backing a chat pane: the app's environment with the ingest
    /// socket pinned to this instance's path, so the listener and the hook
    /// emitters always agree even when the app environment lacks the key.
    static func daemonChildEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment[socketEnvKey] = ingestSocketPath(environment: base)
        return environment
    }

    private static func suffixed(_ base: String, variant: String, slug: String?) -> String {
        guard let slug = slug.flatMap(SocketPathMarkerFiles.sanitizeSocketSlug), !slug.isEmpty else {
            return "\(base)-\(variant)"
        }
        return "\(base)-\(variant)-\(slug)"
    }

    @usableFromInline static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}
