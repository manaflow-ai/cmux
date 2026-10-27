/// Heap pages that are never purged: the ``PurgeablePages`` of a cache whose pictures stay resident (feature
/// `purgeableImageCaches` off). Volatile and non-volatile are the same state for them, and they always count
/// in the footprint.
public final class ResidentPages: PurgeablePages {
    private let address: UInt
    public let byteCount: Int
    public var isPurgeable: Bool { false }

    /// Allocates `byteCount` zeroed bytes.
    ///
    /// - Parameter byteCount: The bytes it holds.
    public init?(byteCount: Int) {
        guard byteCount > 0 else { return nil }
        // SAFETY: a new allocation of `byteCount` bytes, zeroed whole here and freed only in deinit.
        let base = unsafe UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        address = unsafe UInt(bitPattern: base)
        self.byteCount = byteCount
    }

    deinit {
        // SAFETY: `address` is the allocation made in init, freed once here.
        unsafe UnsafeMutableRawPointer(bitPattern: address)?.deallocate()
    }

    public var baseAddress: UnsafeMutableRawPointer? {
        // SAFETY: `address` is this object's allocation, which lives until its deinit.
        unsafe UnsafeMutableRawPointer(bitPattern: address)
    }

    public func makeVolatile() {}

    public func makeNonVolatile() -> Bool { true }
}
