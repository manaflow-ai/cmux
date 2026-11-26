import Foundation

/// Recognizes the bounded launch evidence emitted by `sr claude proxy` and builds
/// the resume argv that re-invokes Subrouter instead of replaying a captured
/// Claude argv.
///
/// `sr claude proxy` hands Claude a private, per-launch `--settings` file that
/// carries the proxy token, account routing headers and base URL, and deletes it
/// when `sr` exits. A replayed `claude --resume <id>` therefore starts without
/// any of that routing: only `ANTHROPIC_BASE_URL` and `CLAUDE_CONFIG_DIR` survive
/// in the replay-safe capture. Re-invoking `sr claude proxy --resume <id>`
/// regenerates the settings file from the live account pool.
///
/// Provenance is deliberately independent of the captured `ANTHROPIC_BASE_URL`,
/// so a local pool at `http://127.0.0.1:31415` and a hosted one are proven the
/// same way, through two exact-match markers that must agree:
///
/// - ``environmentKey``, exported by `sr` into the Claude child it launches.
/// - ``launchBoundEnvironmentKey``, exported by `cmux-claude-wrapper` only when
///   the argv it received carried Subrouter's private `--settings` file. The
///   wrapper is the one process that still sees that file: its settings merge
///   drops user `--settings` before the argv is captured for restore.
///
/// The first marker leaks to every descendant of the launched Claude, so on
/// its own it proves nothing. Anything short of the agreeing pair leaves the
/// existing restore untouched.
public struct SubrouterClaudeResumeRouting: Sendable, Equatable {
    /// The metadata marker emitted by Subrouter for pooled Claude children.
    public static let environmentKey = "SUBROUTER_CLAUDE_RESUME_COMMAND"

    /// Wrapper-attested copy of the marker bound to the current Claude argv.
    public static let launchBoundEnvironmentKey = "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND"

    /// The account a routed launch was pinned to, exported by
    /// `cmux-claude-wrapper` from the routing headers in the launcher's
    /// private `--settings` file. It is the launcher's resolved choice, so it
    /// survives however the launcher was invoked or what it appended to the
    /// arguments it forwarded.
    public static let accountEnvironmentKey = "CMUX_AGENT_LAUNCH_ROUTED_CLAUDE_ACCOUNT"

    /// Launch metadata the wrapper exports for a routed launch, which the
    /// queued Claude hooks must carry to the session-start capture.
    public static let hookCapturedEnvironmentKeys = [
        environmentKey,
        launchBoundEnvironmentKey,
        accountEnvironmentKey,
    ]

    /// Directory-name prefix of the private settings directory `sr claude proxy` creates.
    public static let privateSettingsDirectoryPrefix = "subrouter-claude-settings-"

    private static let expectedMarkerTokens = [
        ["sr", "claude", "proxy", "--resume"],
        ["subrouter", "claude", "proxy", "--resume"],
    ]

    private static let legacyProxyConfigDirectoryComponents = [
        ".subrouter", "codex", "claude-proxy",
    ]

    /// Environment keys a proven routed restore owns: the markers themselves and
    /// the Claude auth selection that Subrouter regenerates from the live pool.
    /// Replaying the captured values around `sr` would pin the restored session
    /// to launch-time routing that the launcher is about to recompute.
    public static let restoreOwnedEnvironmentKeys: Set<String> = [
        environmentKey,
        launchBoundEnvironmentKey,
        accountEnvironmentKey,
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV",
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS",
    ]

    /// Creates a Subrouter Claude resume router.
    public init() {}

    /// Returns the canonical marker when the captured environment contains the
    /// exact supported command, or `nil` for absent or untrusted values.
    public func capturedMarker(in environment: [String: String]?) -> String? {
        canonicalMarker(environment?[Self.environmentKey])
    }

    /// Returns the canonical form of a marker value, or `nil` unless it is
    /// exactly one of the supported launcher commands.
    public func canonicalMarker(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let tokens = rawValue.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard Self.expectedMarkerTokens.contains(tokens) else { return nil }
        return tokens.joined(separator: " ")
    }

    private func capturedLaunchBoundMarker(in environment: [String: String]?) -> String? {
        if let marker = capturedMarker(in: environment),
           canonicalMarker(environment?[Self.launchBoundEnvironmentKey]) == marker {
            return marker
        }
        return legacyProxyMarker(in: environment)
    }

    /// Recognizes pre-marker sessions whose captured Claude config directory is
    /// Subrouter's private proxy store. These records predate the agreeing
    /// marker pair, but the directory is owned by Subrouter and is not used by
    /// plain Claude or a local managed profile. Require the captured base URL
    /// as a second signal so an orphaned directory alone cannot reroute a
    /// session. Legacy records default to the `sr` launcher, which is the
    /// supported end-user command and is validated against the restore PATH.
    private func legacyProxyMarker(in environment: [String: String]?) -> String? {
        guard let environment,
              environment[Self.environmentKey] == nil,
              environment[Self.launchBoundEnvironmentKey] == nil,
              let configDirectory = environment["CLAUDE_CONFIG_DIR"],
              !configDirectory.isEmpty,
              !configDirectory.hasPrefix("-"),
              !configDirectory.contains("\0"),
              !configDirectory.contains(".."),
              !configDirectory.split(separator: "/").isEmpty,
              let baseURL = environment["ANTHROPIC_BASE_URL"],
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let components = URL(fileURLWithPath: configDirectory).standardized.pathComponents
        guard components.count >= Self.legacyProxyConfigDirectoryComponents.count,
              (0...(components.count - Self.legacyProxyConfigDirectoryComponents.count)).contains(where: { offset in
                  Array(components[offset..<(offset + Self.legacyProxyConfigDirectoryComponents.count)]) == Self.legacyProxyConfigDirectoryComponents
              }) else {
            return nil
        }
        return Self.expectedMarkerTokens[0].joined(separator: " ")
    }

    /// Returns the agreeing marker pair for a durable launch record, or an empty
    /// environment when the launch is not proven.
    ///
    /// Only a wrapper-attested pair is persisted. A legacy proxy record is
    /// recognized again at restore time from its own captured config directory,
    /// so capture never synthesizes attestation the wrapper did not provide.
    public func capturedEnvironment(in environment: [String: String]?) -> [String: String] {
        guard let marker = capturedMarker(in: environment),
              canonicalMarker(environment?[Self.launchBoundEnvironmentKey]) == marker else {
            return [:]
        }
        return [
            Self.environmentKey: marker,
            Self.launchBoundEnvironmentKey: marker,
        ]
    }

    /// The pinned account the wrapper recorded for this launch, or `nil` when
    /// the launch was pooled or the value is not a plain account id. The value
    /// becomes an argument to the launcher, so anything that could read as an
    /// option or carry shell or control characters is refused.
    public func capturedAccount(in environment: [String: String]?) -> String? {
        guard let value = environment?[Self.accountEnvironmentKey],
              (1...256).contains(value.count),
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy(Self.accountScalars.contains) else {
            return nil
        }
        return value
    }

    private static let accountScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@+:=-"
    )

    /// The pinned account as durable launch metadata, or an empty environment.
    public func capturedAccountEnvironment(in environment: [String: String]?) -> [String: String] {
        capturedAccount(in: environment).map { [Self.accountEnvironmentKey: $0] } ?? [:]
    }

    /// Whether the captured launch proves a Subrouter-routed plain `claude` launch.
    ///
    /// cmux launchers (`claudeTeams` and friends) own their own resume shape and
    /// are never rerouted.
    public func provesRoutedLaunch(launcher: String?, environment: [String: String]?) -> Bool {
        let normalizedLauncher = launcher?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedLauncher == nil || normalizedLauncher == "claude" else { return false }
        return capturedLaunchBoundMarker(in: environment) != nil
    }

    /// The launcher program (`sr` or `subrouter`) named by a trusted marker.
    public func launcherExecutable(in environment: [String: String]?) -> String? {
        capturedLaunchBoundMarker(in: environment)?
            .split(separator: " ")
            .first
            .map(String.init)
    }

    /// Builds the Subrouter launcher resume argv only when the launch record
    /// proves the routed invocation. The captured Claude options that are safe
    /// to replay follow the session id; Subrouter's private `--settings` file is
    /// dropped because the launcher issues a fresh one.
    ///
    /// A pinned launch keeps its account: the pin the wrapper recorded
    /// (``accountEnvironmentKey``) when present, else one read from a captured
    /// launcher argv (`sr claude proxy --account x`) on records that predate
    /// it. Otherwise the pool picks the account.
    public func resumeArguments(
        launcher: String?,
        sessionID: String,
        launchArguments: [String],
        environment: [String: String]?,
        launcherPrefix: [String]? = nil
    ) -> [String]? {
        guard provesRoutedLaunch(launcher: launcher, environment: environment),
              let marker = capturedLaunchBoundMarker(in: environment) else {
            return nil
        }
        let tail = launchArguments.isEmpty ? [] : Array(launchArguments.dropFirst())
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: tail) else {
            return nil
        }
        let markerTokens = marker.split(separator: " ").map(String.init)
        let head = capturedAccount(in: environment).map { Array(markerTokens[0..<3]) + ["--account", $0, "--resume"] }
            ?? pinnedLauncherArguments(launcherPrefix, markerTokens: markerTokens)
            ?? markerTokens
        return head
            + [sessionID]
            + removingPrivateSettingsArguments(from: preserved)
    }

    /// The marker's launcher with the captured account pin carried over, when
    /// the captured launcher argv is the same launcher. Only `--account` is
    /// taken: anything else sr was given (a prompt, `--settings`, `--print`)
    /// must not be replayed ahead of `--resume`, and the marker's own program
    /// name is kept so the restore resolves it on PATH as before.
    private func pinnedLauncherArguments(_ launcherPrefix: [String]?, markerTokens: [String]) -> [String]? {
        guard let launcherPrefix,
              let executable = launcherPrefix.first,
              markerTokens.count == 4,
              launcherPrefix.count >= 3,
              (executable as NSString).lastPathComponent == markerTokens[0],
              Array(launcherPrefix[1..<3]) == Array(markerTokens[1..<3]) else {
            return nil
        }
        let options = Array(launcherPrefix.dropFirst(3))
        var account: [String] = []
        var index = 0
        while index < options.count {
            let option = options[index]
            if option == "--account", index + 1 < options.count, !options[index + 1].hasPrefix("-") {
                account = [option, options[index + 1]]
                index += 2
            } else if option.hasPrefix("--account="), option.count > "--account=".count {
                account = [option]
                index += 1
            } else {
                // sr reads its own options only up to the first other
                // argument; everything after that is literal Claude input.
                break
            }
        }
        guard !account.isEmpty else { return nil }
        return Array(markerTokens[0..<3]) + account + ["--resume"]
    }

    /// Whether a `--settings` value names Subrouter's private per-launch file.
    public static func isPrivateSettingsPath(_ value: String) -> Bool {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (path as NSString).lastPathComponent == "settings.json" else { return false }
        let directory = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return directory.hasPrefix(privateSettingsDirectoryPrefix)
    }

    /// Removes `--settings <private>` and `--settings=<private>` for Subrouter's
    /// private file; every other argument, including other `--settings`, stays.
    public func removingPrivateSettingsArguments(from arguments: [String]) -> [String] {
        var selected: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                selected.append(contentsOf: arguments[index...])
                break
            }
            if argument == "--settings", index + 1 < arguments.count,
               Self.isPrivateSettingsPath(arguments[index + 1]) {
                index += 2
                continue
            }
            if argument.hasPrefix("--settings="),
               Self.isPrivateSettingsPath(String(argument.dropFirst("--settings=".count))) {
                index += 1
                continue
            }
            selected.append(argument)
            index += 1
        }
        return selected
    }
}
