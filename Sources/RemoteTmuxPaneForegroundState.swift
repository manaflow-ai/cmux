import Foundation

struct RemoteTmuxPaneForegroundState: Equatable, Sendable {
    /// Field separator inside the reflow subscription value
    /// (`#{alternate_on}|#{pane_current_command}`). A pipe never appears in a tmux
    /// `alternate_on` flag (0/1) and is not part of a process's `comm` name.
    static let fieldSeparator: Character = "|"

    /// Foreground commands whose primary-screen scrollback is safe to reflow on
    /// resize. Everything else is treated as no-reflow so inline TUIs are not
    /// rewrapped into corrupted frames.
    static let plainShellCommands: Set<String> = [
        "bash", "zsh", "fish", "sh", "dash", "ksh", "tcsh", "csh", "ash",
        "mksh", "pdksh", "elvish", "nu", "xonsh", "pwsh", "powershell", "oil", "osh",
        "-bash", "-zsh", "-fish", "-sh", "-dash", "-ksh", "-tcsh", "-csh", "-ash",
    ]

    let alternateOn: Bool
    let command: String

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: Self.fieldSeparator,
            maxSplits: 1, omittingEmptySubsequences: false
        )
        alternateOn = parts.first.map(String.init) == "1"
        command = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
    }

    /// Reflow policy: suppress primary-screen reflow on resize unless the pane is
    /// a known plain shell and not on the alternate screen.
    var suppressesReflow: Bool {
        alternateOn || !Self.plainShellCommands.contains(command)
    }

    /// Close-confirmation policy: active for a known non-shell foreground command
    /// or the alternate screen. Empty/unreported commands are treated as idle.
    var hasActiveCommand: Bool {
        alternateOn || (!command.isEmpty && !Self.plainShellCommands.contains(command))
    }

    /// The coding agent whose CLI is foregrounded in this pane, or `nil` when the
    /// foreground command isn't a known agent. Matches the pane's
    /// `pane_current_command` (the foreground process `comm`) against the known
    /// agent executable names — verified empirically that an interactive `claude`
    /// reports `pane_current_command == "claude"` (not `node`). This is a coarse
    /// "an agent CLI is running in this remote pane" signal: it cannot report
    /// busy/idle or the model (the remote tmux exposes only the comm name).
    var agentProvider: AgentSessionProviderID? {
        guard !command.isEmpty else { return nil }
        return AgentSessionProviderID.allCases.first { $0.executableName == command }
    }
}
