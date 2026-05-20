import Foundation

enum WorkspaceRemoteSSHBatchCommandBuilder {
    static func daemonTransportArguments(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String
    ) -> [String] {
        let script = "exec \(ShellArgumentQuoting.singleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(ShellArgumentQuoting.singleQuoted(script))"
        return ["-T"]
            + batchArguments(configuration: configuration)
            + ["-o", "RequestTTY=no", configuration.destination, command]
    }

    static func daemonSocketForwardArguments(
        configuration: WorkspaceRemoteConfiguration,
        localPort: Int,
        remoteSocketPath: String
    ) -> [String] {
        ["-N", "-T", "-S", "none"]
            + batchArguments(configuration: configuration)
            + [
                "-o", "ExitOnForwardFailure=yes",
                "-o", "RequestTTY=no",
                "-L", "127.0.0.1:\(localPort):\(remoteSocketPath)",
                configuration.destination,
            ]
    }

    static func reverseRelayControlMasterArguments(
        configuration: WorkspaceRemoteConfiguration,
        controlCommand: String,
        forwardSpec: String
    ) -> [String]? {
        guard let controlPath = SSHCommandArgumentSupport.optionValue(named: "ControlPath", in: configuration.sshOptions)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var args = batchArguments(configuration: configuration)
        args += ["-O", controlCommand, "-R", forwardSpec, configuration.destination]
        return args
    }

    private static func batchArguments(configuration: WorkspaceRemoteConfiguration) -> [String] {
        let effectiveSSHOptions = SSHCommandArgumentSupport.backgroundOptions(configuration.sshOptions)
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !SSHCommandArgumentSupport.hasOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        args += ["-o", "BatchMode=yes"]
        // Batch helpers may reuse an existing ControlPath, but must not negotiate a new master.
        args += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }
}
