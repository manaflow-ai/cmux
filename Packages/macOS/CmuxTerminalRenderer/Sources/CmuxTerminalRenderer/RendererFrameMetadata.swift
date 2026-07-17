/// Metadata accompanying one IOSurface frame.
public struct RendererFrameMetadata: Equatable, Sendable {
    public let identity: RendererSurfaceIdentity
    public let sequence: UInt64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scaleX: Double
    public let scaleY: Double

    public init(
        identity: RendererSurfaceIdentity,
        sequence: UInt64,
        pixelWidth: Int,
        pixelHeight: Int,
        scaleX: Double,
        scaleY: Double
    ) {
        self.identity = identity
        self.sequence = sequence
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}
