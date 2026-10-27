/// One cache's count of locked bytes: its ``PurgeableBuffer``s that a reader holds non-volatile now, plus
/// those on pages that are never purged (``ResidentPages``). Each buffer moves its bytes in and out as its
/// first reader starts and its last one ends, on whatever thread that is, so the cache reports volatile and
/// locked bytes apart (``usage(totalBytes:entries:)``) from counters, never a walk.
public final class PurgeableLedger: Sendable {
    private let locked = Atomic<Int>(0)

    public init() {}

    /// The bytes locked now.
    public var lockedBytes: Int { max(0, locked.load(ordering: .relaxed)) }

    /// A reading for the memory report: `totalBytes` split into locked (footprint) and volatile bytes.
    ///
    /// - Parameters:
    ///   - totalBytes: The bytes of every buffer the cache holds.
    ///   - entries: How many entries it holds.
    public func usage(totalBytes: Int, entries: Int) -> MemoryUsage {
        let held = min(lockedBytes, max(0, totalBytes))
        return MemoryUsage(footprintBytes: held, volatileBytes: max(0, totalBytes) - held, entries: entries)
    }

    func add(_ bytes: Int) {
        locked.add(bytes, ordering: .relaxed)
    }

    func subtract(_ bytes: Int) {
        locked.subtract(bytes, ordering: .relaxed)
    }
}
