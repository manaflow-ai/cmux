public import Foundation

/// Builds the command that opens a file in the user's terminal editor.
///
/// The editor is chosen by the shell that runs the command, not by this
/// process: a GUI app launched by LaunchServices has none of the user's shell
/// configuration, so `$VISUAL` and `$EDITOR` are only visible once their shell
/// has loaded its own configuration.
public enum TerminalEditorCommand {
    /// The editor used when neither `$VISUAL` nor `$EDITOR` is set.
    public static let fallbackEditor = "vi"

    /// Builds the payload that runs the user's editor on `url`.
    ///
    /// `exec` replaces the shell, so the surface's child exits with the editor.
    ///
    /// - Parameters:
    ///   - url: The file to open.
    ///   - userShell: Path to the shell that will run the payload, which
    ///     selects the syntax used to read `$VISUAL` and `$EDITOR`.
    public static func command(forOpening url: URL, userShell: String?) -> String {
        let quotedPath = url.path.posixShellSingleQuoted
        guard isFishShell(userShell) else {
            return "exec ${VISUAL:-${EDITOR:-\(fallbackEditor)}} \(quotedPath)"
        }
        return """
        set -l cmux_editor $VISUAL
        test -n "$cmux_editor"; or set cmux_editor $EDITOR
        test -n "$cmux_editor"; or set cmux_editor \(fallbackEditor)
        exec $cmux_editor \(quotedPath)
        """
    }

    /// Builds the startup command for an editor already resolved to an absolute
    /// path, so no shell has to look it up again.
    ///
    /// The result starts with the executable, never `exec`: Ghostty prepends
    /// `exec -l` to startup commands, and `exec -l exec …` makes the shell look
    /// for a program named `exec`.
    public static func command(
        forOpening url: URL,
        resolvedEditor: ResolvedTerminalEditor
    ) -> String {
        let words = [resolvedEditor.executablePath.posixShellSingleQuoted]
            + resolvedEditor.arguments.map(\.posixShellSingleQuoted)
            + [url.path.posixShellSingleQuoted]
        return words.joined(separator: " ")
    }

    private static func isFishShell(_ userShell: String?) -> Bool {
        guard let userShell else { return false }
        return (userShell as NSString).lastPathComponent == "fish"
    }
}
