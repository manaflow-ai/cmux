import Foundation
internal import CmuxFoundation

// Batch (non-interactive) SSH argument composition for daemon transports and
// reverse-relay ControlMaster operations, formerly the app target's
// `WorkspaceRemoteSSHBatchCommandBuilder` namespace enum. These are pure
// transforms of the configuration; the argument text is wire/process
// behavior, do not alter it.
extension WorkspaceRemoteConfiguration {
    private static let batchSSHControlOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    /// `ssh` argv that execs `<remotePath> serve --stdio` (plus
    /// `--persistent --slot <slot>` and its validated relay lease port when a
    /// persistent daemon slot is configured) on the destination.
    /// Argument text is wire/process behavior; do not alter.
    ///
    /// The positional command conflicts with a host-configured
    /// `RemoteCommand` unless overridden (issue #7246); the override leads
    /// so it also wins (first value per option) over configured options.
    public func daemonTransportArguments(remotePath: String) -> [String] {
        var serveArguments = ["serve", "--stdio"]
        if let slot = persistentDaemonSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            serveArguments += ["--persistent", "--slot", slot]
            if let relayPort, relayPort > 0, relayPort <= 65_535 {
                serveArguments += ["--persistent-lease-port", String(relayPort)]
            }
        }
        let daemonCommand = ([remotePath] + serveArguments)
            .map(\.shellSingleQuoted)
            .joined(separator: " ")
        let script = "exec \(daemonCommand)"
        let command = "sh -c \(script.shellSingleQuoted)"
        return ["-T"]
            + SSHHostConfiguredRemoteCommand().overrideArguments
            + batchSSHArguments()
            + ["-o", "RequestTTY=no", destination, command]
    }

    /// `ssh` argv that forwards `127.0.0.1:<localPort>` to the baked VM
    /// daemon's Unix socket (`-N`, no remote command). Argument text is
    /// wire/process behavior; do not alter.
    public func daemonSocketForwardArguments(localPort: Int, remoteSocketPath: String) -> [String] {
        ["-N", "-T", "-S", "none"]
            + batchSSHArguments()
            + [
                "-o", "ExitOnForwardFailure=yes",
                "-o", "RequestTTY=no",
                "-L", "127.0.0.1:\(localPort):\(remoteSocketPath)",
                destination,
            ]
    }

    /// `ssh -O <controlCommand>` argv that drives a reverse forward on the
    /// configured ControlMaster socket, or `nil` when no usable `ControlPath`
    /// option is present in the effective SSH options.
    ///
    /// - Parameters:
    ///   - controlCommand: OpenSSH multiplexing command, such as `forward` or `cancel`.
    ///   - forwardSpec: Exact reverse-forward specification.
    ///   - effectiveSSHOptions: Options used by the foreground SSH connection.
    /// - Returns: Arguments for `/usr/bin/ssh`, or `nil` without a usable control socket.
    public func reverseRelayControlMasterArguments(
        controlCommand: String,
        forwardSpec: String,
        effectiveSSHOptions: [String]
    ) -> [String]? {
        if let controlMaster = Self.firstSSHOptionValue(
            named: "ControlMaster",
            in: effectiveSSHOptions
        )?.lowercased(),
           ["no", "false", "off", "0"].contains(controlMaster) {
            return nil
        }
        guard let controlPath = Self.firstSSHOptionValue(
            named: "ControlPath",
            in: effectiveSSHOptions
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var arguments = batchSSHArguments(sshOptions: effectiveSSHOptions)
        arguments += ["-O", controlCommand, "-R", forwardSpec, destination]
        return arguments
    }

    /// Builds a non-interactive command that reuses the supplied exact ControlPath.
    ///
    /// - Parameters:
    ///   - command: Remote shell command to execute.
    ///   - effectiveSSHOptions: Options carrying the authenticated ControlPath.
    /// - Returns: Arguments for `/usr/bin/ssh`.
    public func batchSSHCommandArguments(
        command: String,
        effectiveSSHOptions: [String]
    ) -> [String] {
        ["-T"]
            + SSHHostConfiguredRemoteCommand().overrideArguments
            + batchSSHArguments(sshOptions: effectiveSSHOptions)
            + ["-o", "RequestTTY=no", destination, command]
    }

    // Shared batch-mode `ssh` options: keepalives, BatchMode, no new
    // ControlMaster (existing ControlPath sockets may be reused), port,
    // identity, then the configuration's options minus
    // ControlMaster/ControlPersist.
    private func batchSSHArguments() -> [String] {
        batchSSHArguments(sshOptions: sshOptions)
    }

    private func batchSSHArguments(sshOptions: [String]) -> [String] {
        let effectiveSSHOptions = backgroundSSHOptions(sshOptions)
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !Self.hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        args += ["-o", "BatchMode=yes"]
        // Batch helpers may reuse an existing ControlPath, but must not negotiate a new master.
        args += ["-o", "ControlMaster=no"]
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    // Trimmed options minus ControlMaster/ControlPersist (ControlPath is
    // kept so batch helpers can reuse an existing master's socket).
    private func backgroundSSHOptions(_ options: [String]) -> [String] {
        let resolver = SSHAgentSocketResolver()
        return Self.trimmedSSHOptions(options).filter { option in
            guard let key = resolver.optionKey(option) else { return false }
            return !Self.batchSSHControlOptionKeys.contains(key)
        }
    }

    // OpenSSH uses the first obtained value for these command-line options.
    private static func firstSSHOptionValue(
        named key: String,
        in options: [String]
    ) -> String? {
        let loweredKey = key.lowercased()
        for option in trimmedSSHOptions(options) {
            let parts = option.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            guard parts.count == 2, parts[0].lowercased() == loweredKey else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

extension String {
    // POSIX single-quoting for embedding a value in an `sh -c` script
    // (`'` becomes `'"'"'`). File-private on the natural receiver; quoting
    // output is wire/process behavior, do not alter.
    fileprivate var shellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
