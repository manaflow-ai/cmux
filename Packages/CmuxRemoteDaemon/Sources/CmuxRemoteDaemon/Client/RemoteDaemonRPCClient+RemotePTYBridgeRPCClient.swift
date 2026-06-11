public import Foundation

/// ``RemotePTYBridgeRPCClient`` conformance: the PTY bridge server drives the
/// daemon through this seam. `writePTY` and `detachPTY` are satisfied by the
/// primary declarations in `RemoteDaemonRPCClient+RPC.swift`; attach maps
/// ``RemoteDaemonPTYEvent`` to ``RemotePTYBridgeEvent`` case-for-case,
/// exactly like the legacy `WorkspaceRemotePTYBridgeRPCClient` extension.
extension RemoteDaemonRPCClient: RemotePTYBridgeRPCClient {
    /// Attaches via ``attachPTY(sessionID:attachmentID:cols:rows:command:requireExisting:queue:onEvent:)``,
    /// translating each PTY event into its bridge equivalent on `queue`.
    public func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (RemotePTYBridgeEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment {
        try attachPTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            cols: cols,
            rows: rows,
            command: command,
            requireExisting: requireExisting,
            queue: queue
        ) { event in
            switch event {
            case .ready:
                onEvent(.ready)
            case .data(let data):
                onEvent(.data(data))
            case .exit:
                onEvent(.exit)
            case .error(let detail):
                onEvent(.error(detail))
            }
        }
    }
}
