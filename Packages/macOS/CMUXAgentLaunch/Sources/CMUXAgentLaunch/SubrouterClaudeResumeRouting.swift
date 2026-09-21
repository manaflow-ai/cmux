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

    /// Directory-name prefix of the private settings directory `sr claude proxy` creates.
    public static let privateSettingsDirectoryPrefix = "subrouter-claude-settings-"

    private static let expectedMarkerTokens = [
        ["sr", "claude", "proxy", "--resume"],
        ["subrouter", "claude", "proxy", "--resume"],
    ]

    /// Environment keys a proven routed restore owns: the markers themselves and
    /// the Claude auth selection that Subrouter regenerates from the live pool.
    /// Replaying the captured values around `sr` would pin the restored session
    /// to launch-time routing that the launcher is about to recompute.
    public static let restoreOwnedEnvironmentKeys: Set<String> = [
        environmentKey,
        launchBoundEnvironmentKey,
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
        guard let marker = capturedMarker(in: environment),
              canonicalMarker(environment?[Self.launchBoundEnvironmentKey]) == marker else {
            return nil
        }
        return marker
    }

    /// Returns the agreeing marker pair for a durable launch record, or an empty
    /// environment when the launch is not proven.
    public func capturedEnvironment(in environment: [String: String]?) -> [String: String] {
        guard let marker = capturedLaunchBoundMarker(in: environment) else { return [:] }
        return [
            Self.environmentKey: marker,
            Self.launchBoundEnvironmentKey: marker,
        ]
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
    public func resumeArguments(
        launcher: String?,
        sessionID: String,
        launchArguments: [String],
        environment: [String: String]?
    ) -> [String]? {
        guard provesRoutedLaunch(launcher: launcher, environment: environment),
              let marker = capturedLaunchBoundMarker(in: environment) else {
            return nil
        }
        let tail = launchArguments.isEmpty ? [] : Array(launchArguments.dropFirst())
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: tail) else {
            return nil
        }
        return marker.split(separator: " ").map(String.init)
            + [sessionID]
            + removingPrivateSettingsArguments(from: preserved)
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
