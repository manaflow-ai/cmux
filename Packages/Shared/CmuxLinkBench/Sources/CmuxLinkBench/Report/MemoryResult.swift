/// Process memory: the high-water mark at start and end of the run, and the
/// final footprint. One rig per process, so the delta is the rig's.
public struct MemoryResult: Codable, Sendable {
    public var baselineMaxResidentMiB: Double
    public var finalMaxResidentMiB: Double
    public var finalFootprintMiB: Double
}
