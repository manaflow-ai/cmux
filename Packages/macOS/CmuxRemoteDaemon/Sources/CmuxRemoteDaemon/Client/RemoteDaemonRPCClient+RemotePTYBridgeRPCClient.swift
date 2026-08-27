public import Foundation

/// ``RemotePTYBridgeRPCClient`` conformance: the PTY bridge server drives the
/// daemon through this seam. `writePTY` and `detachPTY` are satisfied by the
/// primary declarations in `RemoteDaemonRPCClient+RPC.swift`; attach maps
/// ``RemoteDaemonPTYEvent`` to ``RemotePTYBridgeEvent`` case-for-case,
/// exactly like the legacy `WorkspaceRemotePTYBridgeRPCClient` extension.
extension RemoteDaemonRPCClient: RemotePTYBridgeRPCClient {
    /// Whether the connected daemon advertised the optional
    /// ``RemoteDaemonCapability/ptyInputSeqAck`` capability in its hello.
    public var supportsInputSeqAck: Bool {
        stateQueue.sync {
            advertisedCapabilities.contains(Self.optionalPTYInputSeqAckCapability)
        }
    }

    /// Attaches via ``attachPTY(sessionID:attachmentID:cols:rows:command:requireExisting:queue:onEvent:)``,
    /// translating each PTY event into its bridge equivalent on `queue`.
    public func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        inputSeqAck: Bool,
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
            inputSeqAck: inputSeqAck,
            queue: queue
        ) { event in
            switch event {
            case .ready:
                onEvent(.ready)
            case .data(let data):
                onEvent(.data(data))
            case .inputAck(let seq):
                onEvent(.inputAck(seq: seq))
            case .exit:
                onEvent(.exit)
            case .error(let detail):
                onEvent(.error(detail))
            }
        }
    }
}
