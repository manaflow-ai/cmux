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

    /// The view owns its output queue, and the queue holds itself only weakly
    /// between work items. A surface free still queued behind other work when
    /// the view is released has to run anyway, or the surface and its
    /// runtime leak.
    @MainActor
    @Test("a surface free queued behind other work runs after its view is released")
    func queuedSurfaceFreeOutlivesItsView() async throws {
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
        try #require(weakRuntime != nil)
        #expect(await view?.processOutputAndWait(Data("X".utf8)) == true)

        // Hold the output queue so the free waits behind this item.
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        view?.outputQueue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        #expect(blockerStarted.wait(timeout: .now() + 5) == .success)

        view?.prepareForDismantle()
        view?.disposeSurface()
        view = nil
        let viewDeadline = ContinuousClock.now + .seconds(10)
        while weakView != nil, ContinuousClock.now < viewDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        releaseBlocker.signal()
        #expect(weakView == nil)

        let runtimeDeadline = ContinuousClock.now + .seconds(10)
        while weakRuntime != nil, ContinuousClock.now < runtimeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
