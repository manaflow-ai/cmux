import Foundation

/// Identifies the syntax family parsed by a terminal's interactive shell.
nonisolated public enum TerminalStartupShellDialect: Equatable, Sendable {
    /// A shell that accepts cmux's generated POSIX command syntax.
    case posix
    /// Nushell, which requires generated POSIX commands to run through `/bin/sh`.
    case nushell

    /// Maps a shell executable path to its command dialect by basename.
    ///
    /// Every supported shell other than `nu` receives the POSIX dialect.
    ///
    /// - Parameter shell: A shell executable path, or `nil` when unavailable.
    /// - Returns: The syntax family accepted by that shell.
    public static func forShellPath(_ shell: String?) -> TerminalStartupShellDialect {
        guard let shell = shell?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shell.isEmpty else {
            return .posix
        }
        return URL(fileURLWithPath: shell).lastPathComponent == "nu" ? .nushell : .posix
    }

    /// Resolves the local login-shell dialect from an injected environment.
    ///
    /// - Parameter environment: The process environment whose `SHELL` value
    ///   identifies the login shell.
    /// - Returns: The syntax family accepted by the selected login shell.
    public static func loginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalStartupShellDialect {
        forShellPath(environment["SHELL"])
    }

    /// Dialect assumed for input typed into a remote host after attach.
    ///
    /// The SSH bootstrap does not currently report the remote shell back to
    /// cmux, so remote inputs retain the POSIX dialect used historically.
    public static let remoteHost: TerminalStartupShellDialect = .posix
}
