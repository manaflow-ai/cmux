import Foundation

/// Synthesizes a hookless, directory-scoped resume binding for a remote agent
/// (issue #7989, Tier 1).
///
/// A remote host without cmux agent hooks never reports a session checkpoint,
/// so the strongest honest restore signal is "agent `<kind>` was running in
/// `<directory>`". This synthesizer turns that pair into a conservative
/// `cd <dir> && <agent> --continue || <agent>` command bound to the panel's
/// persistent-SSH PTY, mirroring how `TmuxResumeParser` turns a locally
/// observed tmux client into a `process-detected` binding.
///
/// Known limitation (accepted for hookless remotes): a directory-scoped
/// continue command resumes whatever conversation the agent considers most
/// recent for that directory. When several sessions of the same agent share
/// one working directory, the wrong conversation can be continued.
enum RemoteAgentContinueSynthesizer {
    /// `SurfaceResumeBindingSnapshot.source` value for synthesized bindings;
    /// must match `SurfaceResumeBindingSnapshot.isRemoteSynthesized`.
    static let source = "remote-synthesized"

    /// Builds a directory-scoped continue binding, or nil when the agent kind
    /// has no trustworthy sessionless continue invocation or the remote
    /// working directory is unknown.
    static func binding(
        kind: RestorableAgentKind,
        remoteWorkingDirectory: String?,
        remoteContext: SurfaceResumeRemoteContext,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) -> SurfaceResumeBindingSnapshot? {
        guard let workingDirectory = normalized(remoteWorkingDirectory),
              let continueCommand = directoryScopedContinueCommand(for: kind) else {
            return nil
        }
        // Same cd guard as every other startup command
        // (`TerminalStartupWorkingDirectoryPrefix`): tolerate a deleted saved
        // directory instead of failing before the agent launches. The command
        // runs on the remote host, so the local claude/codex wrapper-resolver
        // tokens are deliberately not used here — mirroring
        // `SurfaceResumeBindingSnapshot.remoteStartupInput()`, which renders
        // remote commands with `repairPortableAgentExecutable: false`.
        let command = TerminalStartupWorkingDirectoryPrefix.prefix(
            continueCommand,
            workingDirectory: workingDirectory
        )
        return SurfaceResumeBindingSnapshot(
            name: "\(kind.displayName) continue",
            kind: kind.rawValue,
            command: command,
            cwd: workingDirectory,
            source: source,
            autoResume: true,
            launchFlavor: .persistentSSH(remoteContext),
            updatedAt: updatedAt
        )
    }

    /// Sessionless continue templates. Deliberately conservative: only agents
    /// with a documented directory-level continue invocation are covered; the
    /// per-session commands in `docs/agent-hooks.md` all need a checkpoint id
    /// that a hookless remote cannot provide. The `|| <agent>` fallback starts
    /// a fresh session when the agent has nothing to continue in that
    /// directory, so restore never dead-ends on a continue error.
    private static func directoryScopedContinueCommand(
        for kind: RestorableAgentKind
    ) -> String? {
        switch kind {
        case .claude:
            // Continues the most recent conversation recorded for the current
            // working directory (claude's session store is cwd-keyed).
            return "claude --continue || claude"
        case .codex:
            // Resumes the most recently used codex session.
            return "codex resume --last || codex"
        default:
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
