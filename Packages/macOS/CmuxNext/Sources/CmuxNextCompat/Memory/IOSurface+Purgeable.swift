public import IOSurface

/// A hidden frame's IOSurface is purgeable (lead decision, cx-8w027.19.1): the pages it keeps (a hidden
/// terminal surface's presented frame, an evicted terminal's last frame, a hidden page's snapshot) are
/// volatile while nothing shows them, so memory pressure takes them without a policy of ours, and they are
/// made non-volatile again before they show. A purged frame is not shown: its owner drops it (a terminal's
/// renderer is told to, `TerminalPresentation.purge`, since only the renderer writes what a surface presents).
///
/// Purgeable pages and the app-wide hidden frame list (`HiddenFrameLRU`, `memoryHiddenFrameLRU`) work
/// together: the kernel takes a volatile frame's pages when it needs them, and the list drops the frame
/// itself (its soft limit, its 5 min cull, a warning level), so neither waits for the other. Pictures that
/// are not IOSurfaces keep their bytes in ``PurgeablePages``.
extension IOSurface {
    /// kIOSurfacePurgeable* by value (IOSurfaceTypes.h): the imported Swift names differ by SDK.
    public static let purgeableNonVolatile: UInt32 = 0
    public static let purgeableVolatile: UInt32 = 1
    public static let purgeableEmpty: UInt32 = 2

    /// Marks the pages volatile (nothing shows them).
    public func makeVolatile() {
        var old: UInt32 = 0
        // SAFETY: IOSurfaceSetPurgeable writes one UInt32, the previous state, into `old` during the call.
        _ = unsafe IOSurfaceSetPurgeable(self, Self.purgeableVolatile, &old)
    }

    /// Makes the pages non-volatile for a reader; false when the system purged them meanwhile.
    public func reclaim() -> Bool {
        var old: UInt32 = 0
        // SAFETY: IOSurfaceSetPurgeable writes one UInt32, the previous state, into `old` during the call.
        _ = unsafe IOSurfaceSetPurgeable(self, Self.purgeableNonVolatile, &old)
        return old != Self.purgeableEmpty
    }
}
