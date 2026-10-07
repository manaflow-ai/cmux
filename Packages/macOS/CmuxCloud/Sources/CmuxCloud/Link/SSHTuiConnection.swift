import CmuxCloudTui
import CmuxCore
import CmuxFoundation
import CmuxSettings
import CryptoKit
import Foundation

/// Stable SSH identity and launch configuration for a cmux-tui session.
public struct SSHTuiConnection: Sendable {
    /// Creates an SSH connection description with a stable launch environment.
    ///
    /// - Parameters:
    ///   - configuration: The persisted SSH workspace configuration.
    ///   - environment: The local environment inherited by SSH children.
    public init(
        configuration: WorkspaceRemoteConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configuration = configuration
        inheritedEnvironment = environment
    }

    public let configuration: WorkspaceRemoteConfiguration
    /// The complete local environment captured for this connection's children.
    /// Capturing it once keeps route identity and every SSH launch consistent.
    private let inheritedEnvironment: [String: String]

    /// The local environment used by the carrier, browser proxy and SSH helpers.
    public var sshProcessEnvironment: [String: String] {
        configuration.sshProcessEnvironment(inheriting: inheritedEnvironment)
    }

    /// Coding agents whose cmux-tui hooks the host installs on each attach, so
    /// their state reaches the sidebar. Not part of the link identity.
    public var agentHookProviders: [String] = []

    /// The providers whose Settings > Integrations hook toggle is on.
    public static func agentHookProviders(defaults: UserDefaults) -> [String] {
        let settings = AgentIntegrationSettingsStore(defaults: defaults)
        return (settings.claudeCodeHooksEnabled ? ["claude"] : []) + (settings.codexHooksEnabled ? ["codex"] : [])
    }

    /// Includes the SSH account and configuration so aliases with different routes never share a link.
    public var id: String { "ssh:" + identityDigest }
    public var identityDigest: String {
        digest(includeAgentSocket: false)
    }

    /// Includes the authentication agent so separate credentials never share a master.
    private var routeIdentityDigest: String {
        digest(includeAgentSocket: true)
    }

    /// Hashes the route inputs that must share, or avoid sharing, an SSH master.
    private func digest(includeAgentSocket: Bool) -> String {
        let resolver = SSHAgentSocketResolver(environment: [:])
        let sharingOptions = SSHConnectionSharingOptions()
        let persistentOptions = configuration.sshOptions.filter {
            let key = resolver.optionKey($0) ?? ""
            return !["controlmaster", "controlpersist", "controlpath"].contains(key)
                && sharingOptions.routeSensitiveIdentifier(in: [$0]) == nil
        }
        var components = [configuration.destination, configuration.port.map(String.init) ?? "",
                          configuration.identityFile ?? ""] + persistentOptions
        if let routeIdentifier = sharingOptions.routeSensitiveIdentifier(in: configuration.sshOptions) {
            components.append(routeIdentifier)
        }
        if includeAgentSocket {
            if let agent = sshProcessEnvironment["SSH_AUTH_SOCK"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !agent.isEmpty {
                components.append(agent)
            } else if configuration.agentSocketPathOverrideIsSet {
                components.append("<disabled-agent>")
            } else {
                components.append("<no-agent>")
            }
        }
        return SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public var session: String { "cmux" }

    public var authenticationArguments: [String] {
        routeCheckArguments(batchMode: false) + ["--", configuration.destination, "true"]
    }

    /// A prompt-free `ssh … true` over the carrier's route.
    public var preflightArguments: [String] {
        // OpenSSH keeps the first value it reads, so a caller's ConnectTimeout still wins.
        routeCheckArguments(batchMode: true) + ["-o", "ConnectTimeout=15", "--", configuration.destination, "true"]
    }

    private func routeCheckArguments(batchMode: Bool) -> [String] {
        var arguments = ["/usr/bin/ssh", "-T", "-o", batchMode ? "BatchMode=yes" : "BatchMode=no",
                         "-o", "RemoteCommand=none", "-o", "RequestTTY=no"]
        if let port = configuration.port { arguments += ["-p", String(port)] }
        if let identity = configuration.identityFile { arguments += ["-i", identity] }
        for option in sshOptions { arguments += ["-o", option] }
        return arguments
    }

    /// The caller's options plus cmux's shared ControlMaster, as 0.64.25's
    /// connection broker used for every connect. Snapshots keep only the
    /// cmux-owned ControlPath an open used, so these defaults restore the rest;
    /// without a shared master, batch mode can't log in on a password-only host.
    private var sshOptions: [String] {
        let sharing = SSHConnectionSharingOptions()
        let resolver = SSHAgentSocketResolver(environment: [:])
        let effectiveAgent = sshProcessEnvironment["SSH_AUTH_SOCK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let agentRouteIsSensitive = configuration.agentSocketPathOverrideIsSet
            || (effectiveAgent?.isEmpty == false)
        var options = configuration.sshOptions
        if agentRouteIsSensitive,
           let suppliedControlPath = resolver.optionValue(named: "ControlPath", in: options),
           suppliedControlPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "none" {
            if sharing.cmuxOwnedControlPath(in: options) != nil {
                // A restored cmux carrier owns the exact authenticated master
                // recorded in its snapshot. Keep that socket even for legacy
                // snapshots that predate the opaque route marker; dropping it
                // can make a password-only host unreachable in batch mode.
                let restoresAuthenticatedCmuxCarrier =
                    configuration.restoredSSHSession?.sshSessionOwner == "cmux-tui"
                if !restoresAuthenticatedCmuxCarrier {
                    // New launches recompute a cmux-owned path from the
                    // captured agent route so different credentials cannot
                    // share a master.
                    options.removeAll { resolver.optionKey($0) == "controlpath" }
                }
            } else {
                // A caller-owned path cannot encode the agent route. Never let
                // it connect a master opened with a different credential.
                options = options.filter { resolver.optionKey($0) != "controlpath" }
                options.append("ControlPath=none")
            }
        }
        var routeSensitiveOptions = configuration.identityFile.map { ["IdentityFile=\($0)"] } ?? []
        if let agent = configuration.agentSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
            routeSensitiveOptions.append("IdentityAgent=\(agent)")
        } else if configuration.agentSocketPathOverrideIsSet {
            // Keep an explicitly disabled agent from sharing a master opened
            // with the caller's inherited agent, and make the route identity
            // reflect that OpenSSH behavior.
            routeSensitiveOptions.append("IdentityAgent=none")
        }
        if agentRouteIsSensitive, configuration.agentSocketPathOverrideIsSet == false {
            // An inherited socket is not an SSH option, but it is still part
            // of the credentials carried by a multiplexed master.
            routeSensitiveOptions.append("inherited-agent-route")
        }
        return sharing.mergingDefaults(
            into: options,
            routeSensitiveOptions: routeSensitiveOptions,
            routeIdentifier: routeIdentityDigest
        )
    }

    /// The daemon owns the login shell and therefore keeps it alive when SSH disconnects.
    public var shellCommand: [String] {
        if let restored = configuration.restoredSSHSession,
           restored.sshSessionOwner == nil,
           let sessionName = configuration.terminalProfile.tmuxSessionName {
            return RemoteTmuxCommandBuilder(arguments: ["attach-session", "-t", "=\(sessionName)"]).remoteCommandArguments
        }
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

    public func arguments(stateDirectory: String, deviceName: String, upgrade: Bool = false) -> [String] {
        var arguments = ["remote", "ssh", configuration.destination, "--headless", "--json",
                         "--exit-with-parent", "--lanes", "single", "--carrier",
                         "--session", session, "--state-dir", stateDirectory]
        var sshArguments = ["-o", "BatchMode=yes", "-o", "RequestTTY=no", "-o", "RemoteCommand=none"]
        if let port = configuration.port { sshArguments += ["-p", String(port)] }
        if let identity = configuration.identityFile { sshArguments += ["-i", identity] }
        for option in sshOptions { sshArguments += ["-o", option] }
        // The carrier is a headless exec channel that reconnects for its whole
        // lifetime. Batch mode turns a prompt it cannot answer into OpenSSH's
        // own failure. Interactive authentication and host-key prompts precede
        // this launch (SSHTuiPreflight), and verification stays OpenSSH's.
        for argument in sshArguments { arguments += ["--ssh-arg", argument] }
        arguments += ["--device-name", deviceName]
        if upgrade { arguments.append("--upgrade") }
        if !agentHookProviders.isEmpty {
            arguments += ["--agent-hooks", agentHookProviders.joined(separator: ",")]
        }
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

    /// Opens one authenticated, loopback-only TCP route through the SSH carrier.
    /// The app pre-binds and retains the browser-visible loopback socket. The
    /// child inherits it on stdin so its exit cannot expose the URL to a local
    /// service that later reuses the port.
    public func forwardArguments(stateDirectory: String, target: CloudPortForwardTarget) -> [String] {
        var arguments = ["remote", "forward", "ssh://" + configuration.destination,
                         "--workspace-root", "/", "--host", target.host,
                         "--port", String(target.port), "--listen-fd", "0", "--scheme", "http",
                         "--exit-with-parent", "--lanes", "single", "--carrier",
                         "--session", session, "--state-dir", stateDirectory,
                         "--device-name", CloudTuiClientPaths.deviceName()]
        var sshArguments = ["-o", "BatchMode=yes", "-o", "RequestTTY=no", "-o", "RemoteCommand=none"]
        if let port = configuration.port { sshArguments += ["-p", String(port)] }
        if let identity = configuration.identityFile { sshArguments += ["-i", identity] }
        for option in sshOptions { sshArguments += ["-o", option] }
        for argument in sshArguments { arguments += ["--ssh-arg", argument] }
        return arguments
    }
}
