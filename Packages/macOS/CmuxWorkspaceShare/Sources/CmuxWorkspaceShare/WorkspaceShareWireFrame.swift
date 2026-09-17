import Foundation

/// One versioned frame exchanged over a workspace-share WebSocket.
public struct WorkspaceShareWireFrame: Codable, Equatable, Sendable {
    /// Protocol version. Version one is the only accepted value.
    public let v: Int
    /// Stable frame type such as `access.requested` or `terminal.vt`.
    public let type: String
    /// Monotonic sequence for this sender.
    public let seq: UInt64
    /// JSON object payload.
    public let payload: WorkspaceShareJSONValue

    /// Creates a wire frame.
    /// - Parameters:
    ///   - v: Protocol version.
    ///   - type: Frame type.
    ///   - seq: Sender sequence.
    ///   - payload: Frame payload.
    public init(v: Int = 1, type: String, seq: UInt64, payload: WorkspaceShareJSONValue) {
        self.v = v
        self.type = type
        self.seq = seq
        self.payload = payload
    }
}
