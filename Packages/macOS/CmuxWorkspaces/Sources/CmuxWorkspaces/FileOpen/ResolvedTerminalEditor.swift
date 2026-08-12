public import Foundation

/// A terminal editor resolved to an absolute executable path, its arguments,
/// and the `PATH` its shell would have given it.
///
/// Resolving once lets the editor launch with no shell in between, which on a
/// configured machine is the difference between tens and hundreds of
/// milliseconds per open.
public struct ResolvedTerminalEditor: Codable, Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    /// The interactive shell's `PATH`, carried so the editor still finds the
    /// tools it shells out to (language servers, formatters) without paying for
    /// shell startup.
    public let pathEnvironment: String

    public init(executablePath: String, arguments: [String], pathEnvironment: String) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.pathEnvironment = pathEnvironment
    }
}

/// Asks the user's interactive shell which editor it would use.
public enum TerminalEditorProbe {
    /// Shell payload printing the configured editor, its absolute path, and `PATH`.
    ///
    /// POSIX-family syntax only; fish keeps the interactive-shell path, which
    /// needs no probe.
    public static let payload = """
    cmux_editor="${VISUAL:-${EDITOR:-vi}}"
    set -- $cmux_editor
    cmux_path=$(command -v "$1" 2>/dev/null) || cmux_path=""
    printf '%s\\n%s\\n%s\\n' "$cmux_editor" "$cmux_path" "$PATH"
    """

    /// Parses ``payload`` output, returning `nil` when the editor could not be
    /// resolved to an absolute path.
    public static func parse(_ output: String) -> ResolvedTerminalEditor? {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3 else { return nil }

        let words = lines[0].split(whereSeparator: \.isWhitespace).map(String.init)
        let executablePath = lines[1]
        // An empty PATH would leave the editor unable to find the tools it
        // spawns, so an incomplete probe falls back to the shell path.
        guard !words.isEmpty, executablePath.hasPrefix("/"), !lines[2].isEmpty else {
            return nil
        }

        return ResolvedTerminalEditor(
            executablePath: executablePath,
            arguments: Array(words.dropFirst()),
            pathEnvironment: lines[2]
        )
    }
}
