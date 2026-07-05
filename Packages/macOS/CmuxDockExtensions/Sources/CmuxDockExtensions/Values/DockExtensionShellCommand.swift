import Foundation

extension DockExtensionBuildStep {
    /// The step's argv rendered as one shell command string for the Dock's
    /// login-shell startup wrapper (which `eval`s the string in the user's
    /// login shell so PATH and toolchains resolve like a normal terminal).
    ///
    /// Arguments made only of safe characters stay bare; everything else is
    /// POSIX single-quoted (`'` → `'\''`), which bash, zsh, and fish all
    /// accept.
    public var shellCommand: String {
        command.dockExtensionShellCommand
    }
}

extension DockExtensionPane {
    /// The pane's argv rendered as one shell command string for the Dock's
    /// login-shell startup wrapper (see ``DockExtensionBuildStep/shellCommand``
    /// for the quoting rules).
    public var shellCommand: String {
        command.dockExtensionShellCommand
    }
}

extension [String] {
    /// Renders the array as one shell command string, quoting each argument
    /// that needs it.
    var dockExtensionShellCommand: String {
        map(\.dockExtensionShellQuoted).joined(separator: " ")
    }
}

extension String {
    /// The argument POSIX single-quoted when it contains characters outside
    /// the safe set. An empty argument renders as `''`.
    var dockExtensionShellQuoted: String {
        guard !isEmpty else { return "''" }
        let isSafe = unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9",
                 "_", ".", "/", ":", "=", "@", "%", "+", ",", "-":
                return true
            default:
                return false
            }
        }
        if isSafe { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
