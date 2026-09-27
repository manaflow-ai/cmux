import Foundation

/// The resume context a Claude hook replayed from an SSH relay host may carry.
///
/// A relay host is authenticated but not trusted. It may name the session to resume, the remote
/// directory the session lives in, and the argv words of the agent's nearest ancestors so the Mac
/// can detect a user-declared external launcher. It never supplies a command, argv, environment,
/// or settings: the Mac builds the resume command itself from ``AgentResumeArgv`` and its own
/// `agents.launchers` declarations, and the launch record it stores is marked with
/// ``launchCommandSource`` so local restore paths refuse to run it on the Mac.
///
/// The bounds below are enforced on the remote host, at relay admission, and again here.
public struct RelayAgentResumeContext: Equatable, Sendable {
    /// Replay environment key carrying the admitted remote working directory.
    public static let remoteWorkingDirectoryEnvironmentKey = "CMUX_AGENT_HOOK_RELAY_REMOTE_CWD"
    /// Replay environment key carrying the admitted ancestor words as a JSON array of arrays.
    public static let ancestorExecutablesEnvironmentKey = "CMUX_AGENT_HOOK_RELAY_ANCESTOR_EXECUTABLES"
    /// `source` of the launch record a relayed binding stores. Restore paths that execute on the
    /// Mac refuse records with this source.
    public static let launchCommandSource = "relay"
    /// The only agent kind the relay admits.
    public static let agentKind = "claude"

    public static let maximumWorkingDirectoryBytes = 1_024
    public static let maximumSessionIDBytes = 128
    public static let maximumAncestors = 8
    public static let maximumWordsPerAncestor = 6
    public static let maximumWordBytes = 128
    public static let maximumAncestorBytes = 2_048

    /// The agent session identifier.
    public let sessionID: String
    /// The absolute directory on the remote host the session was started in.
    public let remoteWorkingDirectory: String
    /// Redacted ancestor words, nearest ancestor first.
    public let ancestorExecutables: [[String]]

    /// Reads the relay resume context from a replayed hook's environment.
    ///
    /// - Parameters:
    ///   - kind: The hook's agent kind. Only `claude` is admitted.
    ///   - sessionID: The session identifier from the hook payload.
    ///   - environment: The replay environment.
    /// - Returns: The context, or `nil` when the event carried no admissible remote directory.
    public init?(kind: String, sessionID: String, environment: [String: String]) {
        guard kind == Self.agentKind,
              Self.isAdmissibleSessionID(sessionID),
              let directory = environment[Self.remoteWorkingDirectoryEnvironmentKey],
              Self.isAdmissibleWorkingDirectory(directory) else {
            return nil
        }
        self.sessionID = sessionID
        remoteWorkingDirectory = directory
        ancestorExecutables = environment[Self.ancestorExecutablesEnvironmentKey]
            .flatMap(Self.decodedAncestorExecutables(json:)) ?? []
    }

    /// The id of the declared launcher the ancestors match, if any.
    ///
    /// - Parameter registry: Launcher declarations from the Mac's own config.
    /// - Returns: The nearest matching launcher id.
    public func detectedLauncherID(in registry: AgentExternalLauncherRegistry) -> String? {
        guard !ancestorExecutables.isEmpty else { return nil }
        return registry.detectedLauncher(ancestorArgvs: ancestorExecutables, kind: Self.agentKind)?.id
    }

    /// The launch record a relayed binding stores.
    ///
    /// It carries no argv, executable, or environment, so the resume argv comes entirely from
    /// ``AgentResumeArgv/builtInKind(kind:sessionId:executablePath:arguments:observedPermissionMode:)``
    /// (`claude --resume <id>`), optionally wrapped in the Mac's own declaration for
    /// `externalLauncherID`.
    ///
    /// - Parameters:
    ///   - externalLauncherID: The detected launcher id, if any.
    ///   - capturedAt: Capture time, in seconds since 1970.
    /// - Returns: A launch record marked with ``launchCommandSource``.
    public func launchCommand(externalLauncherID: String?, capturedAt: TimeInterval) -> AgentLaunchCommand {
        AgentLaunchCommand(
            launcher: Self.agentKind,
            externalLauncher: externalLauncherID,
            arguments: [],
            workingDirectory: remoteWorkingDirectory,
            capturedAt: capturedAt,
            source: Self.launchCommandSource
        )
    }

    /// Whether a stored launch record came from a relay host and so may only run on that host.
    ///
    /// - Parameter source: The launch record's `source`.
    public static func isRelayOrigin(source: String?) -> Bool {
        source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == launchCommandSource
    }

    /// Whether `value` is a session identifier the resume builder may quote.
    public static func isAdmissibleSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumSessionIDBytes
            && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Whether `value` is an absolute remote path within bounds and free of control characters.
    public static func isAdmissibleWorkingDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= maximumWorkingDirectoryBytes
            && !containsControlCharacter(value)
    }

    /// Validates decoded ancestor words against the relay bounds.
    ///
    /// - Parameter value: A decoded JSON value.
    /// - Returns: The words, or `nil` when any bound or type is violated.
    public static func admissibleAncestorExecutables(_ value: Any) -> [[String]]? {
        guard let ancestors = value as? [Any], ancestors.count <= maximumAncestors else { return nil }
        var total = 0
        var result: [[String]] = []
        for ancestor in ancestors {
            guard let words = ancestor as? [Any], !words.isEmpty,
                  words.count <= maximumWordsPerAncestor else { return nil }
            var admitted: [String] = []
            for word in words {
                guard let text = word as? String,
                      text.utf8.count <= maximumWordBytes,
                      !containsControlCharacter(text) else { return nil }
                total += text.utf8.count
                admitted.append(text)
            }
            result.append(admitted)
        }
        return total <= maximumAncestorBytes ? result : nil
    }

    /// Decodes the replay environment's JSON form of the ancestor words.
    public static func decodedAncestorExecutables(json: String) -> [[String]]? {
        guard json.utf8.count <= maximumAncestorBytes * 4,
              let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return admissibleAncestorExecutables(value)
    }

    /// Whether `value` holds a C0 control character or DEL.
    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
