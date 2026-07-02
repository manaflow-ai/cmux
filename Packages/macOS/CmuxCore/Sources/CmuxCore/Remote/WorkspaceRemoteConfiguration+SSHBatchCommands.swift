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
    /// `--persistent --slot <slot>` when a persistent daemon slot is
    /// configured) on the destination for the stdio daemon transport.
    /// Argument text is wire/process behavior; do not alter.
    public func daemonTransportArguments(remotePath: String) -> [String] {
        var serveArguments = ["serve", "--stdio"]
        if let slot = persistentDaemonSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            serveArguments += ["--persistent", "--slot", slot]
        }
        let daemonCommand = ([remotePath] + serveArguments)
            .map(\.shellSingleQuoted)
            .joined(separator: " ")
        let script = "exec \(daemonCommand)"
        let command = "sh -c \(script.shellSingleQuoted)"
        return ["-T"]
            + batchSSHArguments()
            + ["-o", "RequestTTY=no", destination, command]
    }

    /// Local `cmuxd-remote` argv for the stdio daemon transport.
    public func localDaemonTransportArguments() -> [String] {
        var serveArguments = ["serve", "--stdio"]
        if let slot = persistentDaemonSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            serveArguments += ["--persistent", "--slot", slot]
        }
        return serveArguments
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
    /// option is configured. Argument text is wire/process behavior; do not
    /// alter.
    public func reverseRelayControlMasterArguments(
        controlCommand: String,
        forwardSpec: String
    ) -> [String]? {
        guard let controlPath = firstSSHOptionValue(named: "ControlPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var args = batchSSHArguments()
        args += ["-O", controlCommand, "-R", forwardSpec, destination]
        return args
    }

    /// ``reverseRelayControlMasterArguments(controlCommand:forwardSpec:)``
    /// specialized to `-O cancel` for the relay's remote listen port, or
    /// `nil` for a non-positive port. Argument text is wire/process behavior;
    /// do not alter.
    public func reverseRelayControlMasterCancelArguments(relayPort: Int) -> [String]? {
        guard relayPort > 0 else { return nil }
        return reverseRelayControlMasterArguments(
            controlCommand: "cancel",
            forwardSpec: "127.0.0.1:\(relayPort)"
        )
    }

    // Shared batch-mode `ssh` options: keepalives, BatchMode, no new
    // ControlMaster (existing ControlPath sockets may be reused), port,
    // identity, then the configuration's options minus
    // ControlMaster/ControlPersist.
    private func batchSSHArguments() -> [String] {
        let effectiveSSHOptions = backgroundSSHOptions()
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
    private func backgroundSSHOptions() -> [String] {
        let resolver = SSHAgentSocketResolver()
        return Self.trimmedSSHOptions(sshOptions).filter { option in
            guard let key = resolver.optionKey(option) else { return false }
            return !Self.batchSSHControlOptionKeys.contains(key)
        }
    }

    // First non-empty value for an option key, scanning forward. This
    // deliberately differs from SSHAgentSocketResolver.optionValue(named:in:)
    // (which scans in reverse for OpenSSH last-wins semantics): the legacy
    // batch builder used first-match and the reverse-relay behavior is pinned
    // to it.
    private func firstSSHOptionValue(named key: String) -> String? {
        let loweredKey = key.lowercased()
        for option in Self.trimmedSSHOptions(sshOptions) {
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
