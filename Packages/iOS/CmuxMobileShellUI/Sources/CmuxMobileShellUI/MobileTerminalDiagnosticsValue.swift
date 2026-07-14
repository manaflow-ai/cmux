#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileTerminal
import Foundation

private func mobileTerminalDiagnosticsFixed(_ value: Double) -> String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
}

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
            "containerWidth=\(mobileTerminalDiagnosticsFixed(containerWidth))",
            "containerHeight=\(mobileTerminalDiagnosticsFixed(containerHeight))",
            "viewportWidth=\(mobileTerminalDiagnosticsFixed(surface.viewportWidth))",
            "viewportHeight=\(mobileTerminalDiagnosticsFixed(surface.viewportHeight))",
            "renderMinX=\(mobileTerminalDiagnosticsFixed(surface.renderMinX))",
            "renderMinY=\(mobileTerminalDiagnosticsFixed(surface.renderMinY))",
            "renderWidth=\(mobileTerminalDiagnosticsFixed(surface.renderWidth))",
            "renderHeight=\(mobileTerminalDiagnosticsFixed(surface.renderHeight))",
            "backingScale=\(mobileTerminalDiagnosticsFixed(surface.backingScale))",
            "cellPixelWidth=\(mobileTerminalDiagnosticsFixed(surface.cellPixelWidth))",
            "cellPixelHeight=\(mobileTerminalDiagnosticsFixed(surface.cellPixelHeight))",
            "naturalColumns=\(surface.naturalColumns)",
            "naturalRows=\(surface.naturalRows)",
            "effectiveColumns=\(surface.effectiveColumns)",
            "effectiveRows=\(surface.effectiveRows)",
            "baseFontPoints=\(mobileTerminalDiagnosticsFixed(surface.baseFontPoints))",
            "liveFontPoints=\(mobileTerminalDiagnosticsFixed(surface.liveFontPoints))",
            "deliveredEndSeq=\(transport.deliveredEndSeq)",
        ].joined(separator: ";")
    }
}
#endif
