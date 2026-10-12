internal import Foundation

/// A POSIX `sh` script as the one command string `ssh <host> <command>` takes.
///
/// `sshd` hands that string to the account's login shell, which is not always
/// a Bourne shell, so the string has to mean the same thing to whichever shell
/// parses it before `sh` runs the script.
struct RemotePOSIXShellCommand: Sendable, Equatable {
    /// The script `sh` runs on the remote host.
    let script: String

    /// Wraps `script` for execution by the remote host's `sh`.
    init(script: String) {
        self.script = script
    }

    /// The command string to pass to `ssh` after the destination.
    var commandLine: String {
        "sh -c \(script.shellSingleQuoted)"
    }
}
