#if canImport(UIKit) && DEBUG
import CmuxMobileTerminal
import Foundation

struct MobileTerminalDiagnosticsSurfaceValue: Equatable {
    let surfaceID: String
    let surfaceMounted: Bool
    let surfaceGeneration: UInt64
    let activeSurfaceCount: Int
    let pendingSurfaceFreeCount: Int
    let recoveryCount: UInt64
    let viewportWidth: Double
    let viewportHeight: Double
    let renderMinX: Double
    let renderMinY: Double
    let renderWidth: Double
    let renderHeight: Double
    let backingScale: Double
    let cellPixelWidth: Double
    let cellPixelHeight: Double
    let naturalColumns: Int
    let naturalRows: Int
    let effectiveColumns: Int
    let effectiveRows: Int
    let baseFontPoints: Double
    let liveFontPoints: Double

    init(_ snapshot: MobileTerminalSurfaceDiagnosticsSnapshot) {
        surfaceID = snapshot.surfaceID
        surfaceMounted = snapshot.surfaceMounted
        surfaceGeneration = snapshot.surfaceGeneration
        activeSurfaceCount = snapshot.activeSurfaceCount
        pendingSurfaceFreeCount = snapshot.pendingSurfaceFreeCount
        recoveryCount = snapshot.recoveryCount
        viewportWidth = snapshot.viewportWidth
        viewportHeight = snapshot.viewportHeight
        renderMinX = snapshot.renderMinX
        renderMinY = snapshot.renderMinY
        renderWidth = snapshot.renderWidth
        renderHeight = snapshot.renderHeight
        backingScale = snapshot.backingScale
        cellPixelWidth = snapshot.cellPixelWidth
        cellPixelHeight = snapshot.cellPixelHeight
        naturalColumns = snapshot.naturalColumns
        naturalRows = snapshot.naturalRows
        effectiveColumns = snapshot.effectiveColumns
        effectiveRows = snapshot.effectiveRows
        baseFontPoints = snapshot.baseFontPoints
        liveFontPoints = snapshot.liveFontPoints
    }

    init(
        surfaceID: String, surfaceMounted: Bool, surfaceGeneration: UInt64,
        activeSurfaceCount: Int, pendingSurfaceFreeCount: Int, recoveryCount: UInt64,
        viewportWidth: Double, viewportHeight: Double,
        renderMinX: Double, renderMinY: Double, renderWidth: Double, renderHeight: Double,
        backingScale: Double, cellPixelWidth: Double, cellPixelHeight: Double,
        naturalColumns: Int, naturalRows: Int, effectiveColumns: Int, effectiveRows: Int,
        baseFontPoints: Double, liveFontPoints: Double
    ) {
        self.surfaceID = surfaceID
        self.surfaceMounted = surfaceMounted
        self.surfaceGeneration = surfaceGeneration
        self.activeSurfaceCount = activeSurfaceCount
        self.pendingSurfaceFreeCount = pendingSurfaceFreeCount
        self.recoveryCount = recoveryCount
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.renderMinX = renderMinX
        self.renderMinY = renderMinY
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.backingScale = backingScale
        self.cellPixelWidth = cellPixelWidth
        self.cellPixelHeight = cellPixelHeight
        self.naturalColumns = naturalColumns
        self.naturalRows = naturalRows
        self.effectiveColumns = effectiveColumns
        self.effectiveRows = effectiveRows
        self.baseFontPoints = baseFontPoints
        self.liveFontPoints = liveFontPoints
    }
}
#endif
