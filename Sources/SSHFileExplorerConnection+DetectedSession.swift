import CmuxFoundation
import Foundation

struct SSHFileExplorerConnection: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let configFile: String?
    let useIPv4: Bool
    let useIPv6: Bool
    let forwardAgent: Bool
    let compressionEnabled: Bool
    let sshOptions: [String]

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        configFile: String? = nil,
        useIPv4: Bool = false,
        useIPv6: Bool = false,
        forwardAgent: Bool = false,
        compressionEnabled: Bool = false,
        sshOptions: [String]
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.configFile = configFile
        self.useIPv4 = useIPv4
        self.useIPv6 = useIPv6
        self.forwardAgent = forwardAgent
        self.compressionEnabled = compressionEnabled
        self.sshOptions = sshOptions
    }
}

extension SSHFileExplorerProvider {
    nonisolated var remoteIdentity: String {
        "ssh:" + connection.identityComponents.joined(separator: "|")
    }
}

extension SSHFileExplorerConnection {
    /// Components that identify the remote SSH transport and its options.
    var identityComponents: [String] {
        let fields = [
            destination,
            port.map(String.init) ?? "",
            identityFile ?? "",
            configFile ?? "",
            useIPv4 ? "4" : "",
            useIPv6 ? "6" : "",
            forwardAgent ? "A" : "",
            compressionEnabled ? "C" : ""
        ]
            + sshOptions
        return fields.map { "\($0.utf8.count):\($0)" }
    }

    /// Creates the Files transport identity from an interactive SSH process.
    ///
    /// The parsed command-line options stay attached to the connection so
    /// aliases using a config file, jump host, control path, address family, or
    /// agent forwarding continue to reach the same host as the user's session.
    init(detectedSSHSession session: DetectedSSHSession) {
        var options = session.sshOptions
        if let jumpHost = session.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jumpHost.isEmpty,
           !Self.containsOption(options, key: "ProxyJump") {
            options.append("ProxyJump=\(jumpHost)")
        }
        if let controlPath = session.controlPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !controlPath.isEmpty,
           !Self.containsOption(options, key: "ControlPath") {
            options.append("ControlPath=\(controlPath)")
        }

        self.init(
            destination: session.destination,
            port: session.port,
            identityFile: session.identityFile,
            configFile: session.configFile,
            useIPv4: session.useIPv4,
            useIPv6: session.useIPv6,
            forwardAgent: session.forwardAgent,
            compressionEnabled: session.compressionEnabled,
            sshOptions: options
        )
    }

    /// Builds the non-interactive SSH arguments used by Files and Git status.
    /// Paths and commands remain separate process arguments; callers never
    /// interpolate a remote path into a local shell command line.
    func sshArguments(command: String) -> [String] {
        var arguments = SSHHostConfiguredRemoteCommand().overrideArguments
        if useIPv4 {
            arguments.append("-4")
        } else if useIPv6 {
            arguments.append("-6")
        }
        if forwardAgent {
            arguments.append("-A")
        }
        if compressionEnabled {
            arguments.append("-C")
        }
        if let configFile = configFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configFile.isEmpty {
            arguments += ["-F", configFile]
        }
        if let port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in sshOptions {
            arguments += ["-o", option]
        }
        arguments += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        arguments += ["--", destination, command]
        return arguments
    }

    private static func containsOption(_ options: [String], key: String) -> Bool {
        let normalizedKey = key.lowercased()
        return options.contains { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
                .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                .first
                .map(String.init)?
                .lowercased() == normalizedKey
        }
    }
}
