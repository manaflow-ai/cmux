/// What a ``MemoryConsumer`` holds now, for the memory report, `debug.memory` and the release
/// order: one read of counters the consumer keeps, never a walk.
///
/// Chrome's consumers report through `base/trace_event/memory_dump_provider.h`; cmux asks each
/// registered consumer through ``MemoryConsumer/memoryUsage``.
public struct MemoryUsage: Hashable, Sendable, Codable {
    /// Bytes counted in the process's physical footprint (`phys_footprint`), not counting
    /// ``volatileBytes``.
    public let footprintBytes: Int
    /// Bytes in purgeable (volatile) memory, which the kernel takes back without asking and which
    /// `phys_footprint` does not count.
    public let volatileBytes: Int
    /// How many entries the consumer holds (decoded images, saved frames, pages).
    public let entries: Int

    /// Makes one reading.
    ///
    /// - Parameters:
    ///   - footprintBytes: Bytes in the physical footprint.
    ///   - volatileBytes: Bytes in purgeable memory (0 when the consumer holds none).
    ///   - entries: How many entries the consumer holds.
    public init(footprintBytes: Int, volatileBytes: Int = 0, entries: Int) {
        self.footprintBytes = footprintBytes
        self.volatileBytes = volatileBytes
        self.entries = entries
    }

    /// A consumer that holds nothing.
    public static let empty = MemoryUsage(footprintBytes: 0, entries: 0)
}
