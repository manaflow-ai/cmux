#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Ghostty surface dismantle", .serialized)
struct GhosttySurfaceDismantleTests {
    @Test("prepareForDismantle retires the surface and detaches callbacks")
    func prepareForDismantleRetiresSurface() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = DismantleTestDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        defer { view.prepareForDismantle() }

        let surface = try #require(view.surface)
        let bridge = try #require(
            GhosttySurfaceBridge.fromOpaque(ghostty_surface_userdata(surface))
        )
        #expect(bridge.surfaceView === view)

        view.prepareForDismantle()

        #expect(view.surface == nil)
        #expect(bridge.surfaceView == nil)

        // SwiftUI may call dismantle more than once while replacing a host;
        // the second call must not enqueue another free.
        view.prepareForDismantle()
        #expect(view.surface == nil)
    }
}

@MainActor
private final class DismantleTestDelegate: GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {}
}

#endif
