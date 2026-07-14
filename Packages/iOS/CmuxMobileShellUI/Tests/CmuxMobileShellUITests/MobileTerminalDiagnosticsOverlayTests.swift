#if canImport(UIKit) && DEBUG
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Mobile terminal diagnostics overlay")
struct MobileTerminalDiagnosticsOverlayTests {
    @Test("serializes the exact owner-backed diagnostics contract")
    func serializesExactDiagnosticsContract() {
        let value = MobileTerminalDiagnosticsValue(
            surface: .init(
                surfaceID: "surface-1",
                surfaceMounted: true,
                surfaceGeneration: 3,
                activeSurfaceCount: 2,
                pendingSurfaceFreeCount: 1,
                recoveryCount: 3,
                viewportWidth: 390,
                viewportHeight: 511.25,
                renderMinX: 0,
                renderMinY: 7.5,
                renderWidth: 389.5,
                renderHeight: 503.75,
                backingScale: 3,
                cellPixelWidth: 24.125,
                cellPixelHeight: 42.5,
                naturalColumns: 48,
                naturalRows: 36,
                effectiveColumns: 44,
                effectiveRows: 32,
                baseFontPoints: 10,
                liveFontPoints: 11.5
            ),
            transport: .init(
                deliveryQueueDepth: 4,
                replayBarrierDepth: 1,
                replayInFlightDepth: 1,
                pendingViewportAckDepth: 1,
                deliveredEndSeq: 987
            ),
            containerWidth: 390,
            containerHeight: 844
        )

        #expect(value.serialized == [
            "surfaceID=surface-1", "surfaceMounted=1", "surfaceGeneration=3",
            "activeSurfaceCount=2", "pendingSurfaceFreeCount=1", "recoveryCount=3",
            "deliveryQueueDepth=4", "replayBarrierDepth=1", "replayInFlightDepth=1",
            "pendingViewportAckDepth=1", "containerWidth=390.000", "containerHeight=844.000",
            "viewportWidth=390.000", "viewportHeight=511.250", "renderMinX=0.000",
            "renderMinY=7.500", "renderWidth=389.500", "renderHeight=503.750",
            "backingScale=3.000", "cellPixelWidth=24.125", "cellPixelHeight=42.500",
            "naturalColumns=48", "naturalRows=36", "effectiveColumns=44", "effectiveRows=32",
            "baseFontPoints=10.000", "liveFontPoints=11.500", "deliveredEndSeq=987",
        ].joined(separator: ";"))
    }

    @MainActor
    @Test("owns one diagnostics node and one full-bounds container frame")
    func ownsUniqueProbeNodesAndLiveContainerFrame() {
        let overlay = MobileTerminalDiagnosticsOverlayView(surfaceID: "surface-1", store: nil)
        overlay.frame = CGRect(x: 12, y: 34, width: 390, height: 700)
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()

        let elements = (overlay.accessibilityElements as? [UIView]) ?? []
        #expect(elements.filter { $0.accessibilityIdentifier == "MobileTerminalDiagnosticsProbe" }.count == 1)
        #expect(elements.filter { $0.accessibilityIdentifier == "MobileTerminalAvailableContainer" }.count == 1)
        #expect(overlay.availableContainerProbe.frame == overlay.bounds)
        #expect(overlay.diagnosticsProbe.frame == CGRect(x: 0, y: 0, width: 1, height: 1))

        overlay.bounds.size = CGSize(width: 844, height: 326)
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()
        #expect(overlay.availableContainerProbe.frame == overlay.bounds)
    }
}
#endif
