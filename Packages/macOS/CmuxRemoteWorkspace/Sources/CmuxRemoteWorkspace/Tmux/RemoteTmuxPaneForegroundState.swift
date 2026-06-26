import Foundation

public struct RemoteTmuxPaneForegroundState: Equatable, Sendable {
    /// Field separator inside the reflow subscription value
    /// (`#{alternate_on}|#{pane_current_command}`). A pipe never appears in a tmux
    /// `alternate_on` flag (0/1) and is not part of a process's `comm` name.
    public static let fieldSeparator: Character = "|"

    /// Foreground commands whose primary-screen scrollback is safe to reflow on
    /// resize. Everything else is treated as no-reflow so inline TUIs are not
    /// rewrapped into corrupted frames.
    public static let plainShellCommands: Set<String> = [
        "bash", "zsh", "fish", "sh", "dash", "ksh", "tcsh", "csh", "ash",
        "mksh", "pdksh", "elvish", "nu", "xonsh", "pwsh", "powershell", "oil", "osh",
        "-bash", "-zsh", "-fish", "-sh", "-dash", "-ksh", "-tcsh", "-csh", "-ash",
    ]

    public let alternateOn: Bool
    public let command: String

    public init(rawValue: String) {
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
    public var suppressesReflow: Bool {
        alternateOn || !Self.plainShellCommands.contains(command)
    }

    /// Close-confirmation policy: active for a known non-shell foreground command
    /// or the alternate screen. Empty/unreported commands are treated as idle.
    public var hasActiveCommand: Bool {
        alternateOn || (!command.isEmpty && !Self.plainShellCommands.contains(command))
    }
}
