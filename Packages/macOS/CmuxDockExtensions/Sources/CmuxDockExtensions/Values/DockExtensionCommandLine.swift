import Foundation

/// Converts manifest argv arrays into a single shell command string for the
/// Dock's login-shell startup wrapper (which `eval`s the string in the user's
/// login shell so PATH and toolchains resolve like a normal terminal).
///
/// Arguments made only of safe characters stay bare; everything else is
/// POSIX single-quoted (`'` → `'\''`), which bash, zsh, and fish all accept.
public enum DockExtensionCommandLine {
    /// Renders `argv` as one shell command string.
    public static func shellCommand(for argv: [String]) -> String {
        argv.map(quoteIfNeeded).joined(separator: " ")
    }

    /// Quotes a single argument when it contains characters outside the safe
    /// set. An empty argument renders as `''`.
    public static func quoteIfNeeded(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let isSafe = argument.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9",
                 "_", ".", "/", ":", "=", "@", "%", "+", ",", "-":
                return true
            default:
                return false
            }
        }
        if isSafe { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
