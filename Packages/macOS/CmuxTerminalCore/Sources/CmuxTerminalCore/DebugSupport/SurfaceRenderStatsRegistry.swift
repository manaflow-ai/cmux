#if DEBUG
public import Foundation
public import QuartzCore
import IOSurface

/// Per-surface render/flash/present diagnostic counters used by the debug
/// socket and the render-stats probes.
///
/// This holds the seven per-``UUID`` instrumentation caches that previously
/// lived as process-wide `static var` dictionaries on the AppKit
/// `GhosttySurfaceScrollView`. The caches are genuinely process-wide: a surface
/// records into them from its own view instance, while the debug command path
/// (`debug flash_count` / `reset_flash_counts`) and unit tests read or reset
/// them by `surfaceId` with no instance in hand. To keep that aggregation
/// byte-identical, the view owns ONE shared registry instance (a documented
/// `static let` composition default, the LEARNINGS-sanctioned process-wide-cap
/// shape) and forwards to it; this type replaces the loose static dictionaries
/// with a single real owner of the state.
///
/// DEBUG-only diagnostics: carries no production behavior and is compiled out of
/// release builds. `@MainActor` because every caller (the AppKit view, the
/// `@MainActor` debug-command path, and the main-thread unit tests) already runs
/// on the main actor.
@MainActor
public final class SurfaceRenderStatsRegistry {
    private var flashCounts: [UUID: Int] = [:]
    private var drawCounts: [UUID: Int] = [:]
    private var lastDrawTimes: [UUID: CFTimeInterval] = [:]
    private var presentCounts: [UUID: Int] = [:]
    private var dropOverlayShowCounts: [UUID: Int] = [:]
    private var lastPresentTimes: [UUID: CFTimeInterval] = [:]
    private var lastContentsKeys: [UUID: String] = [:]

    /// Creates an empty registry. The composition default is a single shared
    /// instance held by the AppKit surface view.
    public init() {}

    /// The number of navigation/flash events recorded for `surfaceId`.
    public func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    /// Clears every surface's flash counter.
    public func resetFlashCounts() {
        flashCounts.removeAll()
    }

    /// Records one flash for `surfaceId`.
    public func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }

    /// The draw count and last-draw timestamp recorded for `surfaceId`.
    public func drawStats(for surfaceId: UUID) -> (count: Int, last: CFTimeInterval) {
        (drawCounts[surfaceId, default: 0], lastDrawTimes[surfaceId, default: 0])
    }

    /// Clears every surface's draw counters and timestamps.
    public func resetDrawStats() {
        drawCounts.removeAll()
        lastDrawTimes.removeAll()
    }

    /// Records one draw for `surfaceId`, stamping the current media time.
    public func recordSurfaceDraw(_ surfaceId: UUID) {
        drawCounts[surfaceId, default: 0] += 1
        lastDrawTimes[surfaceId] = CACurrentMediaTime()
    }

    /// The number of drop-overlay show animations recorded for `surfaceId`.
    public func dropOverlayShowCount(for surfaceId: UUID) -> Int {
        dropOverlayShowCounts[surfaceId, default: 0]
    }

    /// Records one drop-overlay show animation for `surfaceId`.
    public func recordDropOverlayShow(for surfaceId: UUID) {
        dropOverlayShowCounts[surfaceId, default: 0] += 1
    }

    /// A stable identity key for a layer's current `contents`, including the
    /// IOSurface seed so a re-rendered frame is visible to debug/test tooling
    /// even when the backing object's pointer identity is unchanged.
    public func contentsKey(for layer: CALayer?) -> String {
        guard let modelLayer = layer else { return "nil" }
        // Prefer the presentation layer to better reflect what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return "nil" }
        // Prefer pointer identity for object/CFType contents.
        if let obj = contents as AnyObject? {
            let ptr = Unmanaged.passUnretained(obj).toOpaque()
            var key = "0x" + String(UInt(bitPattern: ptr), radix: 16)

            // For IOSurface-backed terminal layers, the IOSurface object can remain stable while
            // its contents change. Include the IOSurface seed so "new frame rendered" is visible
            // to debug/test tooling even when the pointer identity doesn't change.
            let cf = contents as CFTypeRef
            if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                let surfaceRef = (contents as! IOSurfaceRef)
                let seed = IOSurfaceGetSeed(surfaceRef)
                key += ":seed=\(seed)"
            }

            return key
        }
        return String(describing: contents)
    }

    /// Updates and returns the present-count, last-present time, and contents
    /// key for `surfaceId`, bumping the count only when the layer's contents key
    /// changed since the last call.
    public func updatePresentStats(surfaceId: UUID, layer: CALayer?) -> (count: Int, last: CFTimeInterval, key: String) {
        let key = contentsKey(for: layer)
        if lastContentsKeys[surfaceId] != key {
            presentCounts[surfaceId, default: 0] += 1
            lastPresentTimes[surfaceId] = CACurrentMediaTime()
            lastContentsKeys[surfaceId] = key
        }
        return (presentCounts[surfaceId, default: 0], lastPresentTimes[surfaceId, default: 0], key)
    }
}
#endif
