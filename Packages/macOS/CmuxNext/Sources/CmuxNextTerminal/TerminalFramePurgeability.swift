import IOSurface

/// A hidden terminal's frame is purgeable (lead decision, cx-8w027.19.1): the pages it keeps
/// (a hidden surface's presented frame, an evicted terminal's last frame) are volatile while
/// nothing shows them, so memory pressure takes them without a policy of ours, and they are made
/// non-volatile again before they show. A purged frame is not shown.
extension IOSurface {
    /// kIOSurfacePurgeable* by value (IOSurfaceTypes.h): the imported Swift names differ by SDK.
    static let purgeableNonVolatile: UInt32 = 0
    static let purgeableVolatile: UInt32 = 1
    static let purgeableEmpty: UInt32 = 2

    /// Marks the pages volatile (nothing shows them).
    func makeVolatile() {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(self, Self.purgeableVolatile, &old)
    }

    /// Makes the pages non-volatile for a reader; false when the system purged them meanwhile.
    func reclaim() -> Bool {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(self, Self.purgeableNonVolatile, &old)
        return old != Self.purgeableEmpty
    }
}
