#if canImport(UIKit) && DEBUG
import Foundation

/// DEBUG-only owner-backed snapshot for the selected iOS terminal surface.
///
/// Accessibility reads consume values already owned by the surface lifecycle
/// and its latest applied geometry transaction. They never call libghostty or
/// maintain a second production state machine.
public struct MobileTerminalSurfaceDiagnosticsSnapshot: Equatable, Sendable {
    public let surfaceID: String
    public let surfaceMounted: Bool
    public let surfaceGeneration: UInt64
    public let activeSurfaceCount: Int
    public let pendingSurfaceFreeCount: Int
    public let recoveryCount: UInt64
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let renderMinX: Double
    public let renderMinY: Double
    public let renderWidth: Double
    public let renderHeight: Double
    public let backingScale: Double
    public let cellPixelWidth: Double
    public let cellPixelHeight: Double
    public let naturalColumns: Int
    public let naturalRows: Int
    public let effectiveColumns: Int
    public let effectiveRows: Int
    public let baseFontPoints: Double
    public let liveFontPoints: Double

    static func unmounted(surfaceID: String, activeSurfaceCount: Int) -> Self {
        Self(
            surfaceID: surfaceID,
            surfaceMounted: false,
            surfaceGeneration: 0,
            activeSurfaceCount: activeSurfaceCount,
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
    }
}

extension GhosttySurfaceView {
    /// Reads the selected surface and process-wide active count from the
    /// surface-pointer registry that owns mounted libghostty lifetimes.
    @MainActor
    public static func mobileTerminalDiagnostics(
        surfaceID: String
    ) -> MobileTerminalSurfaceDiagnosticsSnapshot {
        let liveViews = registeredSurfaceViews.values.compactMap(\.value)
        let activeViews = liveViews.filter { !$0.isDismantled && $0.surface != nil }
        guard let view = activeViews.first(where: { $0.hostSurfaceID == surfaceID }) else {
            return .unmounted(surfaceID: surfaceID, activeSurfaceCount: activeViews.count)
        }

        let geometry = view.debugGeometrySnapshotForTesting()
        let naturalColumns = geometry.renderedSize?.columns ?? 0
        let naturalRows = geometry.renderedSize?.rows ?? 0
        let effectiveColumns = geometry.effectiveGrid?.cols ?? naturalColumns
        let effectiveRows = geometry.effectiveGrid?.rows ?? naturalRows
        return MobileTerminalSurfaceDiagnosticsSnapshot(
            surfaceID: surfaceID,
            surfaceMounted: view.surface != nil,
            surfaceGeneration: view.surfaceGeneration,
            activeSurfaceCount: activeViews.count,
            pendingSurfaceFreeCount: view.pendingSurfaceFreeCount,
            // Recovery is the only operation that advances the surface
            // generation, so the generation is also the exact per-view
            // recovery count without a mirrored counter.
            recoveryCount: view.surfaceGeneration,
            viewportWidth: Double(geometry.viewportRect.width),
            viewportHeight: Double(geometry.viewportRect.height),
            renderMinX: Double(geometry.renderRect.minX),
            renderMinY: Double(geometry.renderRect.minY),
            renderWidth: Double(geometry.renderRect.width),
            renderHeight: Double(geometry.renderRect.height),
            backingScale: Double(geometry.screenScale),
            cellPixelWidth: Double(geometry.cellPixelSize.width),
            cellPixelHeight: Double(geometry.cellPixelSize.height),
            naturalColumns: naturalColumns,
            naturalRows: naturalRows,
            effectiveColumns: effectiveColumns,
            effectiveRows: effectiveRows,
            baseFontPoints: Double(geometry.baseFontSize),
            liveFontPoints: Double(geometry.liveFontSize)
        )
    }
}
#endif
