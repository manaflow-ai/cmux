/// What a transport can carry. The DO relay is control-sized: small frames,
/// no bulk, no media.
public struct TransportCapabilities: Sendable, Hashable {
    /// Largest encoded frame the carrier accepts.
    public var maxFrameBytes: Int
    public var carriesBulk: Bool
    public var carriesMedia: Bool

    public init(maxFrameBytes: Int, carriesBulk: Bool, carriesMedia: Bool) {
        self.maxFrameBytes = maxFrameBytes
        self.carriesBulk = carriesBulk
        self.carriesMedia = carriesMedia
    }

    /// WebRTC data channels and direct streams.
    public static let stream = TransportCapabilities(
        maxFrameBytes: 256 * 1024, carriesBulk: true, carriesMedia: true
    )
    /// The HostDO relay (16 KiB frames, transport.md section 6).
    public static let controlSized = TransportCapabilities(
        maxFrameBytes: 16 * 1024, carriesBulk: false, carriesMedia: false
    )
}
