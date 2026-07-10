/// A validated handle to worker-published framebuffer surfaces.
///
/// Pixel storage is retained independently by the host after resolving the
/// global IOSurface identifiers. The shared-memory region contains only the
/// current ring index and sequence number.
public struct SimulatorFrameTransportDescriptor: Codable, Equatable, Sendable {
    /// The POSIX shared-memory control region created by the worker.
    public let sharedMemoryName: String
    /// Global IOSurface identifiers in producer ring order.
    public let surfaceIdentifiers: [UInt32]
    /// Framebuffer width in pixels.
    public let width: Int
    /// Framebuffer height in pixels.
    public let height: Int

    /// Creates one bounded framebuffer transport descriptor.
    public init(
        sharedMemoryName: String,
        surfaceIdentifiers: [UInt32],
        width: Int,
        height: Int
    ) {
        self.sharedMemoryName = sharedMemoryName
        self.surfaceIdentifiers = surfaceIdentifiers
        self.width = width
        self.height = height
    }
}
