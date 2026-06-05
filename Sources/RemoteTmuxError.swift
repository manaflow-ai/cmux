import Foundation

/// Errors raised while talking to a remote tmux server over SSH.
enum RemoteTmuxError: Error, Sendable, Equatable {
    /// The `ssh` (or remote) command exited non-zero for a reason cmux does
    /// not treat as benign. Carries the exit code and captured stderr.
    case commandFailed(exitCode: Int32, stderr: String)

    /// The local `ssh` binary could not be launched at all.
    case launchFailed(String)

    /// The remote host is not reachable / the SSH master could not be opened.
    case unreachable(String)
}

extension RemoteTmuxError {
    /// A short, user-presentable description.
    var message: String {
        switch self {
        case let .commandFailed(exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "remote command failed (exit \(exitCode))"
                : "remote command failed (exit \(exitCode)): \(trimmed)"
        case let .launchFailed(detail):
            return "failed to launch ssh: \(detail)"
        case let .unreachable(detail):
            return "host unreachable: \(detail)"
        }
    }
}

// `String(describing:)` and `error.localizedDescription` both surface the
// crafted ``message`` instead of the default enum reflection dump, so the
// socket/CLI error path (which maps thrown errors via `String(describing:)`)
// returns the readable form rather than `commandFailed(exitCode: 1, …)`.
extension RemoteTmuxError: CustomStringConvertible {
    var description: String { message }
}

extension RemoteTmuxError: LocalizedError {
    var errorDescription: String? { message }
}
