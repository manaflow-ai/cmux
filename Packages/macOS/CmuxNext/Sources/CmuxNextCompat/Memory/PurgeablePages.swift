/// Memory the kernel may take back while it is volatile, with no call into cmux: the seam under
/// ``PurgeableBuffer``. Chrome keeps decoded images in discardable memory for the same reason
/// (`base/memory/discardable_memory.h`; `cc/tiles/software_image_decode_cache.cc` locks a decode while it
/// rasterizes and unlocks it after), and on the Mac its first discardable memory was a `VM_FLAGS_PURGABLE`
/// region toggled with `vm_purgable_control` (`base/memory/discardable_memory_mac.cc`), which
/// ``VirtualMemoryPurgeablePages`` is. Volatile pages are outside the process's `phys_footprint`.
///
/// Tests pass their own pages to purge an entry on demand.
public protocol PurgeablePages: AnyObject, Sendable {
    /// The first byte. The pages stay mapped and writable for the object's lifetime.
    var baseAddress: UnsafeMutableRawPointer? { get }
    /// How many bytes it maps.
    var byteCount: Int { get }
    /// Whether volatile pages may be purged: false for pages that stay resident (``ResidentPages``),
    /// which always count in the footprint.
    var isPurgeable: Bool { get }
    /// Marks the pages volatile: the kernel may take them from now on.
    func makeVolatile()
    /// Makes the pages non-volatile for a reader.
    ///
    /// - Returns: False when the kernel purged them meanwhile: their bytes are gone (zero).
    func makeNonVolatile() -> Bool
}

/// Makes the pages of a ``PurgeableBuffer``: purgeable virtual memory (``virtualMemory``), resident heap
/// memory (``resident``, the behavior with feature `purgeableImageCaches` off), or a test's pages.
public struct PurgeableAllocator: Sendable {
    private let make: @Sendable (Int) -> (any PurgeablePages)?
    /// Whether it is ``resident``: a cache keeps a decoded picture as the image itself (no copy, no color
    /// conversion), as it did before feature `purgeableImageCaches` (``PurgeablePicture/keeping(_:allocator:)``).
    public let isResident: Bool

    /// An allocator that calls `make` with a byte count.
    ///
    /// - Parameter make: Returns pages of at least that many bytes, or nil when it cannot.
    public init(_ make: @escaping @Sendable (Int) -> (any PurgeablePages)?) {
        self.init(make: make, isResident: false)
    }

    private init(make: @escaping @Sendable (Int) -> (any PurgeablePages)?, isResident: Bool) {
        self.make = make
        self.isResident = isResident
    }

    /// New pages of at least `byteCount` bytes, non-volatile; nil when the allocation fails.
    ///
    /// - Parameter byteCount: The bytes needed.
    public func pages(byteCount: Int) -> (any PurgeablePages)? {
        make(byteCount)
    }

    /// `VM_FLAGS_PURGABLE` regions (``VirtualMemoryPurgeablePages``).
    public static let virtualMemory = PurgeableAllocator { VirtualMemoryPurgeablePages(byteCount: $0) }

    /// Heap pages that are never purged (``ResidentPages``), for encoded bytes; a decoded picture stays the image
    /// it was (``isResident``).
    public static let resident = PurgeableAllocator(make: { ResidentPages(byteCount: $0) }, isResident: true)
}
