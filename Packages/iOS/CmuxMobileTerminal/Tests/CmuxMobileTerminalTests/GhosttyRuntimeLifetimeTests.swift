#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

@Suite("Ghostty runtime lifetime")
struct GhosttyRuntimeLifetimeTests {
    /// Freeing libghostty's app tears down every surface created from it, so
    /// a surface freed after its app is a use-after-free. A runtime built
    /// outside `shared()` has to outlive the last surface created from it.
    @MainActor
    @Test("a runtime stays alive until the last surface created from it is freed")
    func runtimeOutlivesItsSurfaces() async throws {
        let delegate = LifetimeTestSurfaceDelegate()
        weak var weakRuntime: GhosttyRuntime?
        weak var weakView: GhosttySurfaceView?
        var view: GhosttySurfaceView?
        do {
            let runtime = try GhosttyRuntime()
            weakRuntime = runtime
            view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
            weakView = view
        }
        // Only the view refers to the runtime now, and its surface still
        // needs the app.
        try #require(weakRuntime != nil)
        #expect(await view?.processOutputAndWait(Data("X".utf8)) == true)

        view?.prepareForDismantle()
        view?.disposeSurface()
        view = nil
        // The surface is freed later on the view's output queue.
        #expect(weakRuntime != nil)

        let deadline = ContinuousClock.now + .seconds(10)
        while weakView != nil || weakRuntime != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakView == nil)
        #expect(weakRuntime == nil)
    }
}

@MainActor
private final class LifetimeTestSurfaceDelegate: GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didProduceInput data: Data
    ) {}

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {}
}
#endif
