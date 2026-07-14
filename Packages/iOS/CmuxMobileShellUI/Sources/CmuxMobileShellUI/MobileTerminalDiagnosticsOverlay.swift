#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileTerminal
import Foundation
import SwiftUI
import UIKit

/// Stable wire value consumed by Priority 4 capture and profiling tooling.
struct MobileTerminalDiagnosticsValue: Equatable {
    struct Surface: Equatable {
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

    struct Transport: Equatable {
        let deliveryQueueDepth: Int
        let replayBarrierDepth: Int
        let replayInFlightDepth: Int
        let pendingViewportAckDepth: Int
        let deliveredEndSeq: UInt64

        init(_ snapshot: MobileTerminalTransportDiagnosticsSnapshot) {
            deliveryQueueDepth = snapshot.deliveryQueueDepth
            replayBarrierDepth = snapshot.replayBarrierDepth
            replayInFlightDepth = snapshot.replayInFlightDepth
            pendingViewportAckDepth = snapshot.pendingViewportAckDepth
            deliveredEndSeq = snapshot.deliveredEndSeq
        }

        init(
            deliveryQueueDepth: Int,
            replayBarrierDepth: Int,
            replayInFlightDepth: Int,
            pendingViewportAckDepth: Int,
            deliveredEndSeq: UInt64
        ) {
            self.deliveryQueueDepth = deliveryQueueDepth
            self.replayBarrierDepth = replayBarrierDepth
            self.replayInFlightDepth = replayInFlightDepth
            self.pendingViewportAckDepth = pendingViewportAckDepth
            self.deliveredEndSeq = deliveredEndSeq
        }
    }

    let surface: Surface
    let transport: Transport
    let containerWidth: Double
    let containerHeight: Double

    init(
        surface: MobileTerminalSurfaceDiagnosticsSnapshot,
        transport: MobileTerminalTransportDiagnosticsSnapshot,
        containerWidth: Double,
        containerHeight: Double
    ) {
        self.surface = Surface(surface)
        self.transport = Transport(transport)
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
    }

    init(surface: Surface, transport: Transport, containerWidth: Double, containerHeight: Double) {
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
            "containerWidth=\(Self.fixed(containerWidth))",
            "containerHeight=\(Self.fixed(containerHeight))",
            "viewportWidth=\(Self.fixed(surface.viewportWidth))",
            "viewportHeight=\(Self.fixed(surface.viewportHeight))",
            "renderMinX=\(Self.fixed(surface.renderMinX))",
            "renderMinY=\(Self.fixed(surface.renderMinY))",
            "renderWidth=\(Self.fixed(surface.renderWidth))",
            "renderHeight=\(Self.fixed(surface.renderHeight))",
            "backingScale=\(Self.fixed(surface.backingScale))",
            "cellPixelWidth=\(Self.fixed(surface.cellPixelWidth))",
            "cellPixelHeight=\(Self.fixed(surface.cellPixelHeight))",
            "naturalColumns=\(surface.naturalColumns)",
            "naturalRows=\(surface.naturalRows)",
            "effectiveColumns=\(surface.effectiveColumns)",
            "effectiveRows=\(surface.effectiveRows)",
            "baseFontPoints=\(Self.fixed(surface.baseFontPoints))",
            "liveFontPoints=\(Self.fixed(surface.liveFontPoints))",
            "deliveredEndSeq=\(transport.deliveredEndSeq)",
        ].joined(separator: ";")
    }

    private static func fixed(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Transparent DEBUG-only sibling mounted over the selected terminal's real
/// SwiftUI layout allocation. Its full-bounds accessibility child is an
/// independent container frame, while the 1×1 diagnostics child reads live
/// surface and transport owners whenever accessibility asks for its value.
@MainActor
final class MobileTerminalDiagnosticsOverlayView: UIView {
    var surfaceID: String
    weak var store: CMUXMobileShellStore?

    let availableContainerProbe = UIView()
    let diagnosticsProbe = MobileTerminalDiagnosticsProbeView()

    init(surfaceID: String, store: CMUXMobileShellStore?) {
        self.surfaceID = surfaceID
        self.store = store
        super.init(frame: .zero)

        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        availableContainerProbe.backgroundColor = .clear
        availableContainerProbe.isUserInteractionEnabled = false
        availableContainerProbe.isAccessibilityElement = true
        availableContainerProbe.accessibilityIdentifier = "MobileTerminalAvailableContainer"

        diagnosticsProbe.backgroundColor = .clear
        diagnosticsProbe.isUserInteractionEnabled = false
        diagnosticsProbe.isAccessibilityElement = true
        diagnosticsProbe.accessibilityIdentifier = "MobileTerminalDiagnosticsProbe"
        diagnosticsProbe.owner = self

        addSubview(availableContainerProbe)
        addSubview(diagnosticsProbe)
        accessibilityElements = [availableContainerProbe, diagnosticsProbe]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        availableContainerProbe.frame = bounds
        diagnosticsProbe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    var diagnosticsValue: String? {
        guard let store else { return nil }
        let surface = GhosttySurfaceView.mobileTerminalDiagnostics(surfaceID: surfaceID)
        let transport = store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID)
        return MobileTerminalDiagnosticsValue(
            surface: surface,
            transport: transport,
            containerWidth: Double(bounds.width),
            containerHeight: Double(bounds.height)
        ).serialized
    }
}

@MainActor
final class MobileTerminalDiagnosticsProbeView: UIView {
    weak var owner: MobileTerminalDiagnosticsOverlayView?

    override var accessibilityValue: String? {
        get { owner?.diagnosticsValue }
        set { /* Read-only live diagnostic. */ }
    }
}

struct MobileTerminalDiagnosticsOverlay: UIViewRepresentable {
    let surfaceID: String
    let store: CMUXMobileShellStore

    func makeUIView(context: Context) -> MobileTerminalDiagnosticsOverlayView {
        MobileTerminalDiagnosticsOverlayView(surfaceID: surfaceID, store: store)
    }

    func updateUIView(_ uiView: MobileTerminalDiagnosticsOverlayView, context: Context) {
        uiView.surfaceID = surfaceID
        uiView.store = store
    }
}
#endif
