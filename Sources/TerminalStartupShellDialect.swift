import Foundation

/// Identifies the syntax family parsed by a terminal's interactive shell.
enum TerminalStartupShellDialect: Equatable {
    case posix
    case nushell

    /// Maps a shell executable path to its dialect by basename. Every supported
    /// shell other than Nushell receives the POSIX command dialect.
    static func forShellPath(_ shell: String?) -> TerminalStartupShellDialect {
        guard let shell = shell?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shell.isEmpty else {
            return .posix
        }
        return URL(fileURLWithPath: shell).lastPathComponent == "nu" ? .nushell : .posix
    }

    /// Dialect of the local login shell used to start terminal surfaces.
    static var loginShell: TerminalStartupShellDialect {
        forShellPath(ProcessInfo.processInfo.environment["SHELL"])
    }

    /// Dialect assumed for input typed into a remote host after attach.
    ///
    /// The SSH bootstrap does not currently report the remote shell back to
    /// cmux, so remote inputs retain the POSIX dialect used historically.
    static let remoteHost: TerminalStartupShellDialect = .posix
}
