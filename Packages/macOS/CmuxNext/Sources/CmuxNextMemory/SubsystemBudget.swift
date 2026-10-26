import Foundation

/// Every memory budget of the app, sized from the Mac's physical memory
/// (plans/cmux-next/chrome-parity/p07-memory.md, section 3.B).
///
/// One value, made once at the composition root, holds the caps that each subsystem used to
/// hard-code: renderer processes, warm terminal surfaces, parked workspaces, decoded-image caches,
/// hibernation snapshots, live hidden pages and kitty image storage. A subsystem reads its field;
/// it never reads `physicalMemory` itself. These are the budgets at normal pressure; the
/// `MemoryCoordinator` scales a consumer's limit under pressure and by the Memory Saver mode.
///
/// ## Chrome reference
///
/// - `content/browser/renderer_host/render_process_host_impl.cc`, `GetMaxRendererProcessCount()`:
///   physical MiB / 2 / `kEstimatedWebContentsMemoryUsage` (85 MB on 64-bit), clamped to
///   [3, 82] on macOS. ``chromiumRendererLimit`` copies the estimate and both clamps.
/// - `components/viz/client/frame_eviction_manager.cc`: Chrome keeps the saved frames of at most
///   min(5, 2 + physical MiB / 256) hidden views and culls them on `OnReleaseMemory`.
///
/// ## cmux differences
///
/// - Renderers get one third of physical memory, not Chrome's half: terminals, the daemons and
///   agents share the Mac with the browser.
/// - Terminal last frames are not capped by a frame-eviction count. They stay volatile (purgeable,
///   outside `phys_footprint`) at the warm-set count, and the kernel takes them under pressure;
///   Chrome's saved frames are not purgeable, so Chrome must count them. Only non-volatile saved
///   frame bytes are capped, at 0.
/// - Content Chrome does not have (terminal surfaces, parked workspaces, agent and internal pages,
///   kitty images) gets a share of physical memory sized the same way: an estimated cost per item.
public nonisolated struct SubsystemBudget: Hashable, Sendable {
    /// The physical memory the budget was sized from, in MiB.
    public let physicalMiB: Int
    /// Whether hidden terminal surfaces can drop their GPU residency (the release API exists).
    public let gpuResidentAvailable: Bool
    /// The most Chromium renderer processes (the `renderer-process-limit` switch).
    public let chromiumRendererLimit: Int
    /// Hidden terminal surfaces kept warm beyond the visible ones (one LRU per app).
    public let warmTerminalSurfaces: Int
    /// Hidden workspaces kept mounted; the least recently shown ones past this are torn down.
    public let parkedWorkspaces: Int
    /// A parked workspace hidden this long is torn down even within ``parkedWorkspaces``.
    public let parkedIdleTimeout: Duration
    /// Bytes shared by every macOS decoded-image cache (previews, page thumbnails, tab thumbnails).
    public let imageCacheBytes: Int
    /// Bytes for the Home transcript and lab row bitmaps.
    public let homeRenderBitmapBytes: Int
    /// Bytes for the snapshots shown in place of hibernated pages.
    public let hibernationSnapshotBytes: Int
    /// Hidden agent pages kept live; the least recently shown ones past this are discarded.
    public let liveHiddenAgentPages: Int
    /// Hidden internal pages kept live; the least recently shown ones past this are discarded.
    public let liveHiddenInternalPages: Int
    /// The app Ghostty's `image-storage-limit` for each terminal surface, in bytes.
    ///
    /// Ghostty applies this limit to each screen, and a surface has a primary and an alternate
    /// screen, so one surface can hold up to 2x this value. A total over surfaces must multiply by 2.
    public let kittyImageBytesPerSurface: Int
    /// The most WebKit pages that share one WebContent process in a related-view group.
    public let webProcessPagesPerGroup: Int

    /// The budget for a Mac with `physicalBytes` of memory.
    ///
    /// - Parameters:
    ///   - physicalBytes: The Mac's physical memory (`hw.memsize`).
    ///   - gpuResidentAvailable: Whether hidden terminal surfaces can drop their GPU residency.
    ///     Without it a warm surface keeps its drawables (about 48 MB), so the warm set stays at
    ///     the size it had before the release API: min(24, max(8, MiB / 64 / 48)).
    public static func forMemory(physicalBytes: UInt64, gpuResidentAvailable: Bool) -> SubsystemBudget {
        SubsystemBudget(physicalMiB: Int(clamping: physicalBytes >> 20), gpuResidentAvailable: gpuResidentAvailable)
    }

    /// The budget for this Mac: the app's one read of `ProcessInfo.physicalMemory`.
    public static func forThisMac(gpuResidentAvailable: Bool) -> SubsystemBudget {
        forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, gpuResidentAvailable: gpuResidentAvailable)
    }

    private init(physicalMiB mib: Int, gpuResidentAvailable: Bool) {
        let mebibyte = 1 << 20
        physicalMiB = mib
        self.gpuResidentAvailable = gpuResidentAvailable
        chromiumRendererLimit = Self.clamp(mib / 3 / Self.estimatedWebContentsMiB, 3, 82)
        warmTerminalSurfaces = gpuResidentAvailable
            ? Self.clamp(mib / 1024, 4, 32)
            : min(24, max(8, mib / 64 / Self.residentTerminalSurfaceMiB))
        parkedWorkspaces = Self.clamp(mib / 2048, 4, 16)
        parkedIdleTimeout = .seconds(15 * 60)
        imageCacheBytes = mib / 128 * mebibyte
        homeRenderBitmapBytes = Self.clamp(mib / 64, 64, 256) * mebibyte
        hibernationSnapshotBytes = mib / 256 * mebibyte
        liveHiddenAgentPages = Self.clamp(mib / 8 / Self.estimatedAgentPageMiB, 4, 32)
        liveHiddenInternalPages = Self.clamp(mib / 4096, 2, 8)
        kittyImageBytesPerSurface = Self.clamp(mib / 4096, 2, 8) * Self.kittyImageBytesPerStep
        webProcessPagesPerGroup = 8
    }

    /// Chrome's `kEstimatedWebContentsMemoryUsage` on 64-bit builds.
    private static let estimatedWebContentsMiB = 85
    /// The measured footprint of one hidden terminal surface that keeps its GPU drawables.
    private static let residentTerminalSurfaceMiB = 48
    /// The estimated footprint of one live agent page.
    private static let estimatedAgentPageMiB = 75
    /// Kitty storage per surface grows in steps of a quarter of today's 5,000,000-byte default.
    private static let kittyImageBytesPerStep = 1_250_000

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(upper, max(lower, value))
    }
}
