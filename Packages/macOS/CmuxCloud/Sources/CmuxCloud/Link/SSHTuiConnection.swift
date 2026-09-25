import CmuxCloudTui
import CmuxCore
import CmuxFoundation
import CryptoKit
import Foundation

/// Stable SSH identity and launch configuration for a cmux-tui session.
public struct SSHTuiConnection: Sendable {
    public init(
        configuration: WorkspaceRemoteConfiguration
    ) {
        self.configuration = configuration
    }

    public let configuration: WorkspaceRemoteConfiguration

    /// Includes the SSH account and configuration so aliases with different routes never share a link.
    public var id: String { "ssh:" + identityDigest }
    public var identityDigest: String {
        let resolver = SSHAgentSocketResolver(environment: [:])
        let persistentOptions = configuration.explicitSSHOptions.filter {
            !["controlmaster", "controlpersist", "controlpath"].contains(resolver.optionKey($0) ?? "")
        }
        let components = [configuration.destination, configuration.port.map(String.init) ?? "",
                          configuration.identityFile ?? ""] + persistentOptions
        return SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public var session: String { "cmux" }

    public var authenticationArguments: [String] {
        var arguments = ["/usr/bin/ssh", "-T", "-o", "BatchMode=no", "-o", "RemoteCommand=none", "-o", "RequestTTY=no"]
        if let port = configuration.port { arguments += ["-p", String(port)] }
        if let identity = configuration.identityFile { arguments += ["-i", identity] }
        for option in configuration.sshOptions { arguments += ["-o", option] }
        return arguments + [configuration.destination, "true"]
    }

    /// The daemon owns the login shell and therefore keeps it alive when SSH disconnects.
    public var shellCommand: [String] {
        if !configuration.terminalProfile.remoteCommandArguments.isEmpty {
            return configuration.terminalProfile.remoteCommandArguments
        }
        if let command = configuration.configuredRemoteCommand, !command.isEmpty {
            return commandArguments(command)
        }
        return ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l"]
    }

    public func commandArguments(_ command: String) -> [String] {
        ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -lc \"$1\"", "cmux-ssh", command]
    }

    public func arguments(stateDirectory: String, deviceName: String) -> [String] {
        var arguments = ["remote", "ssh", configuration.destination, "--headless", "--json",
                         "--exit-with-parent", "--lanes", "single", "--carrier",
                         "--session", session, "--state-dir", stateDirectory]
        var sshArguments = ["-o", "RequestTTY=no", "-o", "RemoteCommand=none"]
        if let port = configuration.port { sshArguments += ["-p", String(port)] }
        if let identity = configuration.identityFile { sshArguments += ["-i", identity] }
        for option in configuration.sshOptions { sshArguments += ["-o", option] }
        // The carrier is an exec channel. Interactive authentication precedes this
        // launch, and host verification must remain OpenSSH's responsibility.
        for argument in sshArguments { arguments += ["--ssh-arg", argument] }
        arguments += ["--device-name", deviceName]
        return arguments
    }

    public func browserArguments(stateDirectory: String) -> [String] {
        var arguments = self.arguments(stateDirectory: stateDirectory, deviceName: CloudTuiClientPaths.deviceName())
        arguments[1] = "browser-proxy"
        arguments[2] = "ssh://" + configuration.destination
        arguments.removeAll { ["--headless", "--json"].contains($0) }
        // SSH services conventionally bind to the host loopback interface. The
        // remote proxy keeps this opt-in separate from Cloud's private-address
        // allowlist so an SSH carrier cannot accidentally broaden Cloud routes.
        arguments += ["--workspace-root", "/", "--allow-loopback",
                      "--allowed-host", "127.0.0.1", "--allowed-host", "localhost",
                      "--allowed-host", "::1"]
        return arguments
    }
}
