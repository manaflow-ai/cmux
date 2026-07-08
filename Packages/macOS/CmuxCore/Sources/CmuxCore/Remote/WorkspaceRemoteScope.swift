public import Foundation

/// Describes how a remote connection applies inside a workspace.
public enum WorkspaceRemoteScope: String, Codable, Equatable, Sendable {
    /// Every eligible surface in the workspace is part of the remote connection.
    case workspace
    /// Only explicitly tracked panes and surfaces are part of the remote connection.
    case pane
}

/// Describes how a newly created surface should inherit a configured remote.
public enum WorkspaceRemoteInheritance: Equatable, Sendable {
    /// Decide inheritance from the source pane or surface identity, if one exists.
    case fromSourcePane(UUID?)
    /// Always inherit the configured remote.
    case always
    /// Never inherit the configured remote.
    case never
}

extension WorkspaceRemoteScope {
    /// Returns whether a new surface should inherit the configured remote.
    ///
    /// Workspace-scoped remotes preserve historical behavior: source-pane policy
    /// inherits even when no source pane exists. Pane-scoped remotes inherit only
    /// from a known source pane that is already tracked as remote.
    ///
    /// - Parameters:
    ///   - policy: The inheritance policy requested by the caller.
    ///   - isSourcePaneRemote: Predicate that answers whether a source pane is remote.
    /// - Returns: `true` when the new surface should inherit the remote.
    public func allowsInheritance(
        policy: WorkspaceRemoteInheritance,
        isSourcePaneRemote: (UUID) -> Bool
    ) -> Bool {
        switch policy {
        case .always:
            return true
        case .never:
            return false
        case .fromSourcePane(let sourcePaneId):
            switch self {
            case .workspace:
                return true
            case .pane:
                guard let sourcePaneId else { return false }
                return isSourcePaneRemote(sourcePaneId)
            }
        }
    }
}

extension WorkspaceRemoteConfiguration {
    /// Returns a copy with a different remote scope.
    ///
    /// Used when a derived workspace, such as a forked agent workspace, adopts
    /// the same connection at a different scope.
    ///
    /// - Parameter scope: The scope to apply to the copied configuration.
    /// - Returns: A configuration with only ``WorkspaceRemoteConfiguration/scope`` changed.
    public func withScope(_ scope: WorkspaceRemoteScope) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: transport,
            destination: destination,
            port: port,
            identityFile: identityFile,
            scope: scope,
            sshOptions: sshOptions,
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
            skipDaemonBootstrap: skipDaemonBootstrap
        )
    }

    /// Returns whether two pane-scoped requests target the same SSH endpoint.
    ///
    /// Pane joins compare only stable transport identity: transport, trimmed
    /// destination, port, and normalized identity path. Per-invocation relay,
    /// token, startup-command, and auth fields are intentionally excluded so a
    /// second `cmux ssh --pane` can join the live connection with fresh secrets.
    ///
    /// - Parameter other: Another remote configuration to compare.
    /// - Returns: `true` when both configurations target the same pane-scoped endpoint.
    public func hasSamePaneScopeTarget(as other: Self) -> Bool {
        transport == other.transport
            && destination.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            && port == other.port
            && Self.normalizedIdentityPath(identityFile)
                == Self.normalizedIdentityPath(other.identityFile)
    }
}
