/// A validated handle to a worker-published packed-BGRA shared-memory ring.
///
/// The descriptor contains no IOSurface identifiers. The host maps the region
/// read-only and deep-copies stable slots before creating presentation images.
public struct SimulatorFrameTransportDescriptor: Codable, Equatable, Sendable {
    /// The permission-restricted POSIX shared-memory ring created by the worker.
    public let sharedMemoryName: String
    /// Framebuffer width in pixels.
    public let width: Int
    /// Framebuffer height in pixels.
    public let height: Int
    /// Packed BGRA bytes in each frame row.
    public let bytesPerRow: Int
    /// Number of pixel slots in the bounded ring.
    public let slotCount: Int
    /// Exact mapped byte count, including the protocol header.
    public let sharedMemoryByteCount: Int

    /// Creates one bounded packed-frame transport descriptor.
    public init(
        sharedMemoryName: String,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        slotCount: Int,
        sharedMemoryByteCount: Int
    ) {
        self.sharedMemoryName = sharedMemoryName
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.slotCount = slotCount
        self.sharedMemoryByteCount = sharedMemoryByteCount
    }
}

extension SimulatorFrameTransportDescriptor {
    /// Process-safe Darwin notification name for this random frame ring.
    package var framePublicationNotificationName: String? {
        guard simulatorFrameSharedMemoryNameIsValid(sharedMemoryName) else { return nil }
        return "com.cmux.simulator.frame." + sharedMemoryName.dropFirst()
    }
}
