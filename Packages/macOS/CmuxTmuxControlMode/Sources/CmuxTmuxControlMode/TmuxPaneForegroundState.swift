import Foundation

/// The tmux state used by both local control-mode and remote tmux mirrors to
/// choose a resize policy. Keeping this classifier in the package prevents
/// the two paths from drifting apart.
public struct TmuxPaneForegroundState: Equatable, Sendable {
    public static let fieldSeparator: Character = "|"

    /// Known shells whose primary screen is safe for local reflow. Unknown
    /// commands are conservative because inline TUIs can run without entering
    /// the alternate screen.
    public static let plainShellCommands: Set<String> = [
        "bash", "zsh", "fish", "sh", "dash", "ksh", "tcsh", "csh", "ash",
        "mksh", "pdksh", "elvish", "nu", "xonsh", "pwsh", "powershell", "oil", "osh",
    ]

    public let alternateOn: Bool
    public let command: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: Self.fieldSeparator,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        alternateOn = parts.first.map(String.init) == "1"
        command = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
    }

    /// tmux reports a login shell with a leading `-`; normalize only that
    /// documented spelling and leave all other names exact.
    public var isPlainShell: Bool {
        let normalized = command.hasPrefix("-") ? String(command.dropFirst()) : command
        return Self.plainShellCommands.contains(normalized)
    }

    public var resizePolicy: TerminalSessionResizePolicy {
        alternateOn || !isPlainShell ? .preserveScreen : .reflow
    }

    public var suppressesReflow: Bool {
        resizePolicy.suppressesLocalReflow
    }

    public var hasActiveCommand: Bool {
        alternateOn || (!command.isEmpty && !isPlainShell)
    }
}
