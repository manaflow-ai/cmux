/// Version and strict allocation limits for the daemon-to-renderer control plane.
public struct RendererControlProtocol: Sendable {
    /// The only wire version accepted by this implementation.
    public static let currentVersion: UInt16 = 1

    /// The fixed byte count of every frame header.
    public static let headerLength = 32

    /// The largest opaque Ghostty semantic scene accepted in one message.
    public static let maximumSemanticSceneLength = 64 * 1_024 * 1_024

    /// The largest resolved renderer configuration accepted in one message.
    public static let maximumResolvedConfigLength = 256 * 1_024

    /// The largest UTF-8 fatal diagnostic accepted in one message.
    public static let maximumDiagnosticLength = 4 * 1_024

    /// The largest accepted physical-pixels-per-point scale.
    public static let maximumBackingScaleFactor = 16.0

    /// The largest payload accepted by any message type.
    public static let maximumPayloadLength = 80 + maximumSemanticSceneLength

    /// The maximum storage needed to receive one complete frame.
    public static let maximumFrameLength = headerLength + maximumPayloadLength

    /// Creates a stateless protocol descriptor.
    public init() {}
}
