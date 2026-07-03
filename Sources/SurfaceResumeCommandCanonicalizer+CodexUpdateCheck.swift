import CMUXAgentLaunch
import Foundation

extension SurfaceResumeCommandCanonicalizer {
    /// Inserts codex's per-invocation update-check suppression override into a
    /// persisted codex resume binding command that predates the override.
    ///
    /// Agent-hook resume bindings are persisted as rendered shell strings, so a
    /// binding saved by a cmux build without the override replays verbatim on
    /// the first relaunch after updating cmux — exactly the restart where
    /// codex's blocking "Update available!" startup picker used to swallow the
    /// restored session. Normalizing at replay time (not persistence) upgrades
    /// stale bindings without a migration. The override is inserted directly
    /// after the parsed `resume <session-id>` words; commands that already
    /// mention `check_for_update_on_startup` (either value) and shapes that
    /// don't parse to a codex resume argv (e.g. `/bin/sh -c '…'` wrapper forms)
    /// are returned unchanged — those self-heal on the next agent-hook persist.
    static func insertingCodexUpdateCheckSuppression(
        in command: String,
        kind: String?
    ) -> String {
        guard kind?.trimmingCharacters(in: .whitespacesAndNewlines) == "codex",
              !command.contains("check_for_update_on_startup") else {
            return command
        }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words, command: command) else {
            return command
        }
        var resumeIndex = executableIndex + 1
        if resumeIndex < words.count, words[resumeIndex].value == "codex-teams" {
            resumeIndex += 1
        }
        let sessionIndex = resumeIndex + 1
        guard sessionIndex < words.count,
              words[resumeIndex].value == "resume",
              !words[sessionIndex].value.hasPrefix("-") else {
            return command
        }
        let overrideText = AgentResumeArgv.codexUpdateCheckSuppressionOverride
            .map(shellQuoted)
            .joined(separator: " ")
        var updated = command
        updated.insert(contentsOf: " " + overrideText, at: words[sessionIndex].range.upperBound)
        return updated
    }
}
