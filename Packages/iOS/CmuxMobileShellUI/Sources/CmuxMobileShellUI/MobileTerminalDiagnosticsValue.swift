#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileTerminal
import Foundation

/// Stable wire value consumed by Priority 4 capture and profiling tooling.
struct MobileTerminalDiagnosticsValue: Equatable {
    let surface: MobileTerminalDiagnosticsSurfaceValue
    let transport: MobileTerminalDiagnosticsTransportValue
    let containerWidth: Double
    let containerHeight: Double

    init(
        surface: MobileTerminalSurfaceDiagnosticsSnapshot,
        transport: MobileTerminalTransportDiagnosticsSnapshot,
        containerWidth: Double,
        containerHeight: Double
    ) {
        self.surface = MobileTerminalDiagnosticsSurfaceValue(surface)
        self.transport = MobileTerminalDiagnosticsTransportValue(transport)
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
    }

    init(
        surface: MobileTerminalDiagnosticsSurfaceValue,
        transport: MobileTerminalDiagnosticsTransportValue,
        containerWidth: Double,
        containerHeight: Double
    ) {
        self.surface = surface
        self.transport = transport
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
    }

    var serialized: String {
        [
            "surfaceID=\(surface.surfaceID)",
            "surfaceMounted=\(surface.surfaceMounted ? 1 : 0)",
            "surfaceGeneration=\(surface.surfaceGeneration)",
            "activeSurfaceCount=\(surface.activeSurfaceCount)",
            "pendingSurfaceFreeCount=\(surface.pendingSurfaceFreeCount)",
            "recoveryCount=\(surface.recoveryCount)",
            "deliveryQueueDepth=\(transport.deliveryQueueDepth)",
            "replayBarrierDepth=\(transport.replayBarrierDepth)",
            "replayInFlightDepth=\(transport.replayInFlightDepth)",
            "pendingViewportAckDepth=\(transport.pendingViewportAckDepth)",
            "containerWidth=\(fixed(containerWidth))",
            "containerHeight=\(fixed(containerHeight))",
            "viewportWidth=\(fixed(surface.viewportWidth))",
            "viewportHeight=\(fixed(surface.viewportHeight))",
            "renderMinX=\(fixed(surface.renderMinX))",
            "renderMinY=\(fixed(surface.renderMinY))",
            "renderWidth=\(fixed(surface.renderWidth))",
            "renderHeight=\(fixed(surface.renderHeight))",
            "backingScale=\(fixed(surface.backingScale))",
            "cellPixelWidth=\(fixed(surface.cellPixelWidth))",
            "cellPixelHeight=\(fixed(surface.cellPixelHeight))",
            "naturalColumns=\(surface.naturalColumns)",
            "naturalRows=\(surface.naturalRows)",
            "effectiveColumns=\(surface.effectiveColumns)",
            "effectiveRows=\(surface.effectiveRows)",
            "baseFontPoints=\(fixed(surface.baseFontPoints))",
            "liveFontPoints=\(fixed(surface.liveFontPoints))",
            "deliveredEndSeq=\(transport.deliveredEndSeq)",
        ].joined(separator: ";")
    }

    private func fixed(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
#endif
