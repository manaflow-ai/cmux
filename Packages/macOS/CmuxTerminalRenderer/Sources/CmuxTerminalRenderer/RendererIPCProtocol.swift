/// Version negotiation for the renderer worker wire protocol.
public enum RendererIPCProtocol {
    /// Increment when a message's meaning changes incompatibly. New optional
    /// operations do not require an increment because operation values are
    /// append-only and unknown values are ignored.
    public static let version: UInt64 = 1

}
