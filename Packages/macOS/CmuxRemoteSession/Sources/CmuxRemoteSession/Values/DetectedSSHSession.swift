import Foundation

/// A value descriptor for a detected SSH-style remote shell connection.
///
/// `DetectedSSHSession` captures the connection parameters parsed from a foreground
/// `ssh`/EternalTerminal command line (destination, port, identity/config files, jump
/// host, ControlMaster path, address-family and agent/compression toggles, plus any
/// passthrough `-o` options). It knows how to translate those parameters into the
/// argument vectors for `scp` and `ssh` invocations, but performs no I/O itself: the
/// process-spawning upload/cleanup service lives app-side and consumes these argument
/// builders.
public struct DetectedSSHSession: Equatable {
    /// The `[user@]host` destination passed to `ssh`/`scp`.
    public let destination: String
    /// The remote port, when an explicit `-p`/`-P` or `Port` option was present.
    public let port: Int?
    /// The identity file path from `-i`/`IdentityFile`, if any.
    public let identityFile: String?
    /// The ssh config file path from `-F`, if any.
    public let configFile: String?
    /// The jump host from `-J`/`ProxyJump`, if any.
    public let jumpHost: String?
    /// The ControlMaster socket path from `-S`/`ControlPath`, if any.
    public let controlPath: String?
    /// Whether IPv4 was forced (`-4`).
    public let useIPv4: Bool
    /// Whether IPv6 was forced (`-6`).
    public let useIPv6: Bool
    /// Whether agent forwarding was requested (`-A`).
    public let forwardAgent: Bool
    /// Whether compression was requested (`-C`).
    public let compressionEnabled: Bool
    /// Passthrough `-o key=value` options preserved verbatim from the command line.
    public let sshOptions: [String]

    /// Creates a detected session descriptor from already-parsed connection parameters.
    public init(
        destination: String,
        port: Int?,
        identityFile: String?,
        configFile: String?,
        jumpHost: String?,
        controlPath: String?,
        useIPv4: Bool,
        useIPv6: Bool,
        forwardAgent: Bool,
        compressionEnabled: Bool,
        sshOptions: [String]
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.configFile = configFile
        self.jumpHost = jumpHost
        self.controlPath = controlPath
        self.useIPv4 = useIPv4
        self.useIPv6 = useIPv6
        self.forwardAgent = forwardAgent
        self.compressionEnabled = compressionEnabled
        self.sshOptions = sshOptions
    }

    /// Builds the `scp` argument vector that uploads `localPath` to `remotePath` on this session's host.
    public func scpArguments(localPath: String, remotePath: String) -> [String] {
        var args: [String] = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-P", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [localPath, "\(Self.scpRemoteDestination(destination)):\(remotePath)"]
        return args
    }

    /// Builds the `ssh` argument vector that runs `command` on this session's host.
    public func sshArguments(command: String) -> [String] {
        var args: [String] = [
            "-T",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [destination, command]
        return args
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { optionKey($0) == loweredKey }
    }

    private static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func scpRemoteDestination(_ destination: String) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return destination }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmedDestination
        }

        guard shouldBracketIPv6Literal(hostPart) else {
            return trimmedDestination
        }

        let bracketedHost = "[\(hostPart)]"
        if let userPart {
            return "\(userPart)@\(bracketedHost)"
        }
        return bracketedHost
    }

    private static func shouldBracketIPv6Literal(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }

    /// Single-quotes `value` for safe inclusion in a remote `sh -c` command string.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
