import Foundation

/// The captured result of running a single command on a remote host over SSH.
struct RemoteTmuxCommandResult: Sendable, Equatable {
    /// The process exit status. `0` is success.
    let exitCode: Int32

    /// Captured standard output, decoded as UTF-8.
    let stdout: String

    /// Captured standard error, decoded as UTF-8.
    let stderr: String

    /// Whether the command exited cleanly.
    var succeeded: Bool { exitCode == 0 }
}
