public import CmuxRemoteDaemon
public import Foundation

extension RemoteDaemonProxyTunnel {
    /// Fetches the authoritative workspace state through this tunnel's RPC client.
    public func getRuntimeState() throws -> RemoteRuntimeStateDocument? {
        let client = try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.runtime-state", code: 30, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return rpcClient
        }
        return try client.getRuntimeState()
    }

    /// Replaces the authoritative workspace state through this tunnel's RPC client.
    public func putRuntimeState(
        schemaVersion: Int,
        state: Data,
        expectedRevision: UInt64?
    ) throws -> RemoteRuntimeStateDocument {
        let client = try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.runtime-state", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return rpcClient
        }
        return try client.putRuntimeState(
            schemaVersion: schemaVersion,
            state: state,
            expectedRevision: expectedRevision
        )
    }
}
