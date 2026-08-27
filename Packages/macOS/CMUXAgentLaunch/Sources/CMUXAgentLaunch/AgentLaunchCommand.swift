import Foundation

/// A captured agent launch kept as structured values for later resume planning.
public struct AgentLaunchCommand: Codable, Equatable, Sendable {
    /// The cmux launcher classification, when one was captured.
    public var launcher: String?
    /// The id of the user-declared external launcher that started the agent, when one was detected.
    ///
    /// This is deliberately separate from ``launcher``: that field is cmux's own classification and
    /// is matched against the agent kind (see ``AgentLaunchCaptureTrust``) and against the built-in
    /// wrapper tokens in ``AgentResumeArgv``, so an unknown value there would invalidate the whole
    /// capture. An external launcher only adds an argv prefix at resume time, resolved from
    /// `agents.launchers` in `cmux.json` (see ``AgentExternalLauncherRegistry``); a capture whose
    /// declaration was removed resumes exactly as it did before, without the wrapper.
    public var externalLauncher: String?
    /// The captured executable path.
    public var executablePath: String?
    /// The captured process arguments, including `argv[0]`.
    public var arguments: [String]
    /// The working directory at initial launch.
    public var workingDirectory: String?
    /// Replay-safe environment captured with the launch.
    public var environment: [String: String]?
    /// The launch user's home directory, retained only to resolve provider
    /// state during verification. It is not replayed as an environment override.
    public var verificationHome: String?
    /// The capture timestamp.
    public var capturedAt: TimeInterval?
    /// The capture source.
    public var source: String?

    /// Creates a structured captured launch.
    ///
    /// - Parameters:
    ///   - launcher: The cmux launcher classification, when one was captured.
    ///   - externalLauncher: The id of the user-declared external launcher that started the agent.
    ///   - executablePath: The captured executable path.
    ///   - arguments: The captured process arguments, including `argv[0]`.
    ///   - workingDirectory: The working directory at initial launch.
    ///   - environment: Replay-safe environment captured with the launch.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture timestamp.
    ///   - source: The capture source.
    public init(
        launcher: String? = nil,
        externalLauncher: String? = nil,
        executablePath: String? = nil,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        verificationHome: String? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.launcher = launcher
        self.externalLauncher = externalLauncher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.verificationHome = verificationHome
        self.capturedAt = capturedAt
        self.source = source
    }
}

extension AgentLaunchCommand {
    /// Returns this record carrying an external launcher id recovered from other records.
    ///
    /// The external launcher is a property of the session, not of whichever capture won an evidence
    /// comparison. Ancestor detection can miss on a later hook — the launcher process may already be
    /// gone — so a record without an id must never erase the id the session was captured with.
    /// https://github.com/manaflow-ai/cmux/issues/10494
    ///
    /// - Parameter candidates: Other records for the same session, in preference order.
    /// - Returns: This record, with the first id found when it has none of its own.
    public func preservingExternalLauncher(from candidates: [AgentLaunchCommand?]) -> AgentLaunchCommand {
        if let own = Self.normalized(externalLauncher) {
            // Store the canonical form: the socket decoder accepts the id as written, so a padded
            // value would otherwise be persisted and compared with its padding intact.
            guard own != externalLauncher else { return self }
            var canonical = self
            canonical.externalLauncher = own
            return canonical
        }
        guard let recovered = candidates
            .lazy
            .compactMap({ Self.normalized($0?.externalLauncher) })
            .first else {
            return self
        }
        var updated = self
        updated.externalLauncher = recovered
        return updated
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
