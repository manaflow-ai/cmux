import Foundation

/// Live-process identity matching for an already-recorded agent session.
///
/// These helpers decide whether a *running* process (its argv and executable)
/// is the same agent that a hook session record captured at launch. The
/// resume/fork path uses them to re-bind a session to a live PID only when the
/// process executable still matches the recorded agent, so a recycled PID or a
/// look-alike process never gets adopted as the session's agent.
///
/// The matcher hangs off ``AgentResumeLaunchCommand`` because the recorded side
/// of the comparison is exactly that captured command. Kind is lowered to an
/// `isClaude` flag at the app seam so the package never imports the app-owned
/// `RestorableAgentKind` enum.
extension AgentResumeLaunchCommand {
    /// The recorded agent's executable basename, or `nil` when neither the
    /// captured executable path nor argv[0] carries a non-empty value.
    ///
    /// Prefers the captured `executablePath`, falling back to argv[0]
    /// (`arguments.first`). The app maps its persisted
    /// `AgentLaunchCommandSnapshot` onto ``AgentResumeLaunchCommand`` at the seam.
    public var recordedExecutableBasename: String? {
        let executable = executablePath.normalizedProcessValue
            ?? arguments.first.normalizedProcessValue
        return executable?.executableBasename
    }

    /// True when a live process's executable plausibly belongs to this recorded
    /// agent.
    ///
    /// A case-insensitive basename match is always sufficient. For Claude, a
    /// `node`/`bun` runtime also matches when any later argument names the
    /// `claude` CLI (a `claude` basename argument, or a path under `/.claude/`
    /// or `/claude/versions/`), since Claude commonly runs as a JS entrypoint.
    ///
    /// - Parameters:
    ///   - isClaude: Whether the recorded agent kind is Claude (lowered from the
    ///     app-side `RestorableAgentKind` at the seam).
    ///   - liveExecutable: The live process executable basename.
    ///   - recordedExecutable: The recorded agent executable basename.
    ///   - arguments: The live process argument vector.
    public func liveProcessExecutableMatchesRecordedAgent(
        isClaude: Bool,
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String]
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }

        guard isClaude else { return false }
        let liveBase = liveExecutable.lowercased()
        guard liveBase == "node" || liveBase == "bun" else { return false }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return argument.executableBasename.compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }
}

extension String {
    /// The last path component of `self`, treating it as a filesystem path.
    public var executableBasename: String {
        (self as NSString).lastPathComponent
    }
}

extension Optional where Wrapped == String {
    /// `self` trimmed of surrounding whitespace, or `nil` when it is missing or
    /// blank.
    public var normalizedProcessValue: String? {
        normalizedNonEmptyValue
    }

    /// `self` trimmed of surrounding whitespace and newlines, or `nil` when it
    /// is missing or empty after trimming.
    public var normalizedNonEmptyValue: String? {
        guard let rawValue = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
