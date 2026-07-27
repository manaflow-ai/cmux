import CmuxSettings
import Darwin
import Foundation

/// The user-configured custom upload rules (`terminal.uploadCommands` in
/// `cmux.json`, see ``TerminalUploadCommandRule``), resolved against an ssh
/// destination. Constructed at the call site (see ``TerminalCustomUploadRunner``)
/// from the rules read out of the settings catalog, so the rule set can be
/// supplied directly in tests.
struct TerminalUploadCommand: Sendable, Equatable {
    let rules: [TerminalUploadCommandRule]

    /// The first enabled rule whose `hostPattern` matches `destination`, or nil
    /// when none matches (the caller then uses the built-in `scp` transport).
    func command(forDestination destination: String) -> String? {
        let host = Self.hostForMatching(destination)
        for rule in rules where rule.enabled {
            guard let pattern = rule.hostPattern else {
                return rule.command
            }
            if Self.hostMatches(pattern: pattern, host: host) {
                return rule.command
            }
        }
        return nil
    }

    /// Normalizes an ssh destination to the host component used for matching:
    /// strips a leading `user@`, unwraps IPv6 brackets (`[::1]` or `[::1]:22` →
    /// `::1`), and lowercases. A non-bracketed `host:port` is matched as-is; the
    /// detected-ssh port is carried separately, so destinations here are bare
    /// hosts in practice.
    static func hostForMatching(_ destination: String) -> String {
        var value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let atIndex = value.lastIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<close])
        }
        return value.lowercased()
    }

    /// ssh_config-style glob match via POSIX `fnmatch` (case-insensitive; host is
    /// pre-lowercased so the pattern is lowercased to match).
    static func hostMatches(pattern: String, host: String) -> Bool {
        let loweredPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !loweredPattern.isEmpty else { return false }
        return loweredPattern.withCString { patternPtr in
            host.withCString { hostPtr in
                fnmatch(patternPtr, hostPtr, 0) == 0
            }
        }
    }

    /// Environment handed to the custom command for one file. The full context is
    /// on the environment (not stdin) so a plain shell one-liner can use it; the
    /// standard process environment is inherited by the caller.
    static func environment(
        localPath: String,
        remotePath: String,
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String]
    ) -> [String: String] {
        var env: [String: String] = [
            "CMUX_UPLOAD_LOCAL_PATH": localPath,
            "CMUX_UPLOAD_REMOTE_PATH": remotePath,
            "CMUX_UPLOAD_DESTINATION": destination,
        ]
        if let port {
            env["CMUX_UPLOAD_PORT"] = String(port)
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["CMUX_UPLOAD_IDENTITY_FILE"] = identityFile
        }
        if !sshOptions.isEmpty {
            env["CMUX_UPLOAD_SSH_OPTIONS"] = sshOptions.joined(separator: "\n")
        }
        return env
    }

    /// The ready-to-type string cmux inserts for one file after the command runs.
    ///
    /// Non-empty command output is typed verbatim — a path, URL, or any reference
    /// the command chose — with C0 control characters and DEL stripped so output
    /// (which is often server-influenced, e.g. a URL an upload service returns)
    /// can't inject escape sequences or newlines into the terminal. When the
    /// command prints nothing, cmux falls back to the shell-escaped remote path it
    /// delivered to, matching the built-in `scp` transport.
    ///
    /// Trust model: the output is *inserted, not executed*. Verbatim insertion is
    /// deliberate — the point of the feature is to compose an arbitrary reference
    /// (the primary consumer is an agent reading the terminal, e.g. "uploaded to
    /// s3://…"), which shell-escaping would corrupt. Stripping control characters
    /// removes auto-submit/escape-sequence injection, so the user still reviews the
    /// text before pressing Enter; the command itself is the user's own
    /// configuration, the same trust boundary as a shell alias they wrote.
    static func emittedText(commandStdout: String, remotePath: String) -> String {
        // Strip C0 control characters and DEL first, then trim. Doing it in this
        // order means output that is only control characters (e.g. an ANSI reset
        // `\u{1b}[…m` with no printable content) collapses to empty and falls back
        // to the remote path, instead of yielding "" and a spurious "no output".
        let sanitized = String(String.UnicodeScalarView(
            commandStdout.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
        )).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return TerminalImageTransferPlanner.escapeForShell(remotePath)
        }
        return sanitized
    }
}
