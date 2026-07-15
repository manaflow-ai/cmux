public import CmuxCore
public import CmuxRemoteDaemon
public import Foundation

extension RemoteProxyBroker {
    /// Fetches the authoritative workspace state through the ready tunnel.
    public func getRuntimeState(configuration: WorkspaceRemoteConfiguration) throws -> RemoteRuntimeStateDocument? {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.getRuntimeState()
        }
    }

    /// Replaces the authoritative workspace state through the ready tunnel.
    public func putRuntimeState(
        configuration: WorkspaceRemoteConfiguration,
        schemaVersion: Int,
        state: Data,
        expectedRevision: UInt64?
    ) throws -> RemoteRuntimeStateDocument {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.putRuntimeState(
                schemaVersion: schemaVersion,
                state: state,
                expectedRevision: expectedRevision
            )
        }
    }
}
