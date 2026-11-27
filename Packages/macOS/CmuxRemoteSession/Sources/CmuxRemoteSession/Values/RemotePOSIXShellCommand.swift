internal import Foundation

/// A POSIX `sh` script as the one command string `ssh <host> <command>` takes.
///
/// `sshd` hands that string to the account's login shell, which is not always
/// a Bourne shell, so the string has to mean the same thing to whichever shell
/// parses it before `sh` runs the script. csh and tcsh refuse a newline inside
/// single quotes, so a multi-line `sh -c '<script>'` never reached `sh` for an
/// account with one of those as its login shell.
///
/// The script therefore travels as one single-quoted word, with the characters
/// a login shell would act on inside it written as `printf %b` escapes, and
/// `sh` rebuilds it:
///
/// - a newline or carriage return, which csh and tcsh refuse inside quotes;
/// - `!`, which csh and tcsh expand as history even inside single quotes;
/// - `\`, which tcsh with `backslash_quote` set, and fish, read as an escape.
///
/// ```swift
/// RemotePOSIXShellCommand(script: "echo one\necho two").commandLine
/// // sh -c 'eval "set --; $(printf %b "$1")"' sh 'echo one\necho two'
/// ```
///
/// The script still runs in that one `sh`, with stdin untouched, `$0` set to
/// `sh` and no positional parameters, as it did under `sh -c '<script>'`.
struct RemotePOSIXShellCommand: Sendable, Equatable {
    /// The script `sh` runs on the remote host.
    let script: String

    /// Wraps `script` for execution by the remote host's `sh`.
    init(script: String) {
        self.script = script
    }

    /// The command string to pass to `ssh` after the destination.
    var commandLine: String {
        // Backslashes first, so the ones the escapes add are left alone. The
        // octal form is `\0ddd`: a digit after the shorter `\ddd` would be
        // read as part of it.
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\0134")
            .replacingOccurrences(of: "!", with: "\\0041")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        // `set --` drops the encoded script from the positional parameters
        // once it has been read, without leaving a variable behind.
        return "sh -c 'eval \"set --; $(printf %b \"$1\")\"' sh \(escaped.shellSingleQuoted)"
    }
}
