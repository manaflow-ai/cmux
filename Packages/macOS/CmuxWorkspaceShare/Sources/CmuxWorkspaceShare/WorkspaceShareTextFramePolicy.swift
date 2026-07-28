/// Encoded-size policy for workspace-share JSON WebSocket frames.
public struct WorkspaceShareTextFramePolicy: Sendable {
    /// Returns whether a host-to-relay JSON frame fits the exclusive 64 KiB limit.
    public static func acceptsHostFrame(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount < ShareProtocolConstants.maximumHostJSONFrameBytes
    }

    /// Returns whether a relay-to-client JSON frame fits the exclusive 1 MiB limit.
    public static func acceptsServerFrame(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount < ShareProtocolConstants.serverJSONFrameByteLimit
    }

    private init() {}
}
