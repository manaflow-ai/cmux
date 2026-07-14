#if canImport(UIKit) && DEBUG
import Foundation

/// DEBUG-only owner-backed snapshot for the selected iOS terminal surface.
///
/// Accessibility reads consume values already owned by the surface lifecycle
/// and its latest applied geometry transaction. They never call libghostty or
/// maintain a second production state machine.
public struct MobileTerminalSurfaceDiagnosticsSnapshot: Equatable, Sendable {
    /// Stable identifier of the terminal surface requested by the verifier.
    public let surfaceID: String
    /// Whether the selected surface currently owns a mounted libghostty surface.
    public let surfaceMounted: Bool
    /// Lifecycle generation of the selected native surface.
    public let surfaceGeneration: UInt64
    /// Number of process-wide mounted terminal surfaces.
    public let activeSurfaceCount: Int
    /// Number of native surface frees waiting for the selected view to drain.
    public let pendingSurfaceFreeCount: Int
    /// Number of recoveries completed by the selected surface view.
    public let recoveryCount: UInt64
    /// Width of the latest applied terminal viewport in points.
    public let viewportWidth: Double
    /// Height of the latest applied terminal viewport in points.
    public let viewportHeight: Double
    /// Horizontal origin of the latest applied render rectangle in points.
    public let renderMinX: Double
    /// Vertical origin of the latest applied render rectangle in points.
    public let renderMinY: Double
    /// Width of the latest applied render rectangle in points.
    public let renderWidth: Double
    /// Height of the latest applied render rectangle in points.
    public let renderHeight: Double
    /// Backing scale used by the latest applied geometry transaction.
    public let backingScale: Double
    /// Width of one measured terminal cell in backing pixels.
    public let cellPixelWidth: Double
    /// Height of one measured terminal cell in backing pixels.
    public let cellPixelHeight: Double
    /// Natural column count applied to the selected surface.
    public let naturalColumns: Int
    /// Natural row count applied to the selected surface.
    public let naturalRows: Int
    /// Effective negotiated column count applied to the selected surface.
    public let effectiveColumns: Int
    /// Effective negotiated row count applied to the selected surface.
    public let effectiveRows: Int
    /// User-selected base font size in points.
    public let baseFontPoints: Double
    /// Font size currently rendering the selected surface in points.
    public let liveFontPoints: Double
}

extension MobileTerminalSurfaceDiagnosticsSnapshot {
    /// Reads the selected surface and process-wide active count from the
    /// surface-pointer registry that owns mounted libghostty lifetimes.
    @MainActor
    public init(surfaceID: String) {
        let liveViews = GhosttySurfaceView.registeredSurfaceViews.values.compactMap(\.value)
        let activeViews = liveViews.filter { !$0.isDismantled && $0.surface != nil }
        guard let view = activeViews.first(where: { $0.hostSurfaceID == surfaceID }) else {
            self.init(
                surfaceID: surfaceID,
                surfaceMounted: false,
                surfaceGeneration: 0,
                activeSurfaceCount: activeViews.count,
                pendingSurfaceFreeCount: 0,
                recoveryCount: 0,
                viewportWidth: 0,
                viewportHeight: 0,
                renderMinX: 0,
                renderMinY: 0,
                renderWidth: 0,
                renderHeight: 0,
                backingScale: 0,
                cellPixelWidth: 0,
                cellPixelHeight: 0,
                naturalColumns: 0,
                naturalRows: 0,
                effectiveColumns: 0,
                effectiveRows: 0,
                baseFontPoints: 0,
                liveFontPoints: 0
            )
            return
        }

        let naturalColumns = view.appliedNaturalSize?.columns ?? 0
        let naturalRows = view.appliedNaturalSize?.rows ?? 0
        let effectiveColumns = view.effectiveGrid?.cols ?? naturalColumns
        let effectiveRows = view.effectiveGrid?.rows ?? naturalRows
        self.init(
            surfaceID: surfaceID,
            surfaceMounted: view.surface != nil,
            surfaceGeneration: view.surfaceGeneration,
            activeSurfaceCount: activeViews.count,
            pendingSurfaceFreeCount: view.pendingSurfaceFreeCount,
            // Recovery is the only operation that advances the surface
            // generation, so the generation is also the exact per-view
            // recovery count without a mirrored counter.
            recoveryCount: view.surfaceGeneration,
            viewportWidth: Double(view.terminalViewportRect.width),
            viewportHeight: Double(view.terminalViewportRect.height),
            renderMinX: Double(view.lastRenderRect.minX),
            renderMinY: Double(view.lastRenderRect.minY),
            renderWidth: Double(view.lastRenderRect.width),
            renderHeight: Double(view.lastRenderRect.height),
            backingScale: Double(view.preferredScreenScale),
            cellPixelWidth: Double(view.cellPixelSize.width),
            cellPixelHeight: Double(view.cellPixelSize.height),
            naturalColumns: naturalColumns,
            naturalRows: naturalRows,
            effectiveColumns: effectiveColumns,
            effectiveRows: effectiveRows,
            baseFontPoints: Double(view.userBaseFontSize),
            liveFontPoints: Double(view.liveFontSize)
        )
    }
}
#endif
