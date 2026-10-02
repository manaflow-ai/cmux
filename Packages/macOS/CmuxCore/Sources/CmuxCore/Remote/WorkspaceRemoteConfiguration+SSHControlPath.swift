internal import CmuxFoundation

extension WorkspaceRemoteConfiguration {
    /// Returns a copy whose first `ControlPath` option is the exact authenticated socket.
    ///
    /// - Parameter controlPath: Resolved path reported while foreground
    ///   authentication still owns the ControlMaster.
    /// - Returns: A configuration that reuses that exact socket identity.
    public func withResolvedSSHControlPath(
        _ controlPath: String
    ) -> WorkspaceRemoteConfiguration {
        let resolver = SSHAgentSocketResolver()
        let resolvedOptions = ["ControlPath=\(controlPath)"] +
            sshOptions.filter {
                resolver.optionKey($0) != "controlpath"
            }
        return WorkspaceRemoteConfiguration(
            transport: transport,
            terminalTransport: terminalTransport,
            terminalProfile: terminalProfile,
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: resolvedOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath,
            ownerWorkspaceID: ownerWorkspaceID,
            managedCloudVMID: managedCloudVMID,
            terminalStartupCommand: terminalStartupCommand,
            foregroundAuthToken: foregroundAuthToken,
            agentSocketPath: agentSocketPath,
            daemonWebSocketEndpoint: daemonWebSocketEndpoint,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap,
            sshControlMasterLeaseGeneration:
                sshControlMasterLeaseGeneration
        )
    }
}
