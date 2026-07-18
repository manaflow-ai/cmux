/// Version and size limits for the renderer-to-Swift frame plane.
public struct TerminalRenderFrameProtocol: Sendable {
    /// The fixed-width metadata wire version implemented by this package.
    public static let currentVersion: UInt16 = 2

    /// The exact byte count of one encoded metadata record.
    public static let metadataLength = 160

    /// The byte count of the per-worker unguessable capability.
    public static let capabilityLength = 32

    /// The largest accepted pixel width or height.
    public static let maximumDimension: UInt32 = 16_384

    /// The largest accepted pixel count, bounding downstream surface work.
    public static let maximumPixelCount: UInt64 = 134_217_728

    /// The largest accepted bootstrap service name in UTF-8 bytes.
    public static let maximumServiceNameLength = 120

    /// Creates a stateless protocol descriptor.
    public init() {}
}
