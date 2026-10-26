import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import CmuxTerminalGhosttyRuntimeTestStubs
import QuartzCore
import Testing
@testable import CmuxTerminal

/// On macOS, `ghostty_surface_new` makes the host view layer-hosting with
/// Ghostty's `IOSurfaceLayer`, whose `-display` calls the renderer through the
/// layer's `display_cb`/`display_ctx` ivars. `ghostty_surface_free` frees that
/// renderer but leaves the layer on the view with both ivars still set, so a
/// Core Animation commit that displays the layer after the free draws through
/// freed memory (#17483: `CA::Layer::display_if_needed` into
/// `ghostty_surface_render_now_with_token` internals, then `object_getClass`
/// on scribbled memory).
///
/// These tests stand in for the native layer with one of the same shape and
/// pin that no teardown path leaves the layer able to reach its renderer once
/// the native free has run.
@MainActor
@Suite(.serialized) struct TerminalSurfaceGhosttyLayerTeardownTests {
    @Test func teardownSurfaceDetachesLayerDisplayBeforeNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let surface = makeSurface()
        let fixture = installGhosttyLayer(on: surface)
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        let probe = NativeFreeDisplayProbe(layer: fixture.layer)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            probe.sampleAtNativeFree()
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }
        fixture.expectDisplayReachesRenderer()

        surface.teardownSurface()

        #expect(await recorder.waitForEventCount(1), "timed out waiting for native free")
        probe.expectDetachedAtNativeFree()
        fixture.expectDisplayNoLongerReachesRenderer()
    }

    @Test func deinitDetachesLayerDisplayBeforeNativeFree() async {
        let recorder = TeardownOrderRecorder()
        var surface: TerminalSurface? = makeSurface()
        let fixture = installGhosttyLayer(on: surface!)
        surface?.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        let probe = NativeFreeDisplayProbe(layer: fixture.layer)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            probe.sampleAtNativeFree()
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }
        fixture.expectDisplayReachesRenderer()

        surface = nil

        #expect(await recorder.waitForEventCount(1), "timed out waiting for native free")
        probe.expectDetachedAtNativeFree()
        fixture.expectDisplayNoLongerReachesRenderer()
    }

    @Test func agentHibernationDetachesLayerDisplayBeforeNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let fixture = installGhosttyLayer(on: surface)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { runtimeSurface.deallocate() }
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let probe = NativeFreeDisplayProbe(layer: fixture.layer)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            probe.sampleAtNativeFree()
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }
        fixture.expectDisplayReachesRenderer()

        #expect(surface.suspendRuntimeSurfaceForAgentHibernation(reason: "test.hibernate"))

        #expect(await recorder.waitForEventCount(1), "timed out waiting for native free")
        probe.expectDetachedAtNativeFree()
        fixture.expectDisplayNoLongerReachesRenderer()
    }

    /// A Ghostty-shaped layer hosted by the surface's view and the fake
    /// renderer its display callback draws through.
    @MainActor
    private struct GhosttyLayerFixture {
        let layer: CALayer
        let renderer: FakeGhosttyRenderer

        func expectDisplayReachesRenderer() {
            layer.display()
            #expect(
                renderer.displayCount == 1,
                "the live layer's display should draw through its renderer"
            )
        }

        /// Drives every way Core Animation reaches `-display`: an explicit
        /// display, a pending needs-display flag and a transaction flush.
        func expectDisplayNoLongerReachesRenderer() {
            let countBeforeDisplay = renderer.displayCount
            #expect(
                FakeGhosttyIOSurfaceLayer.displayCallbackPointer(of: layer) == nil,
                "the layer still holds a display callback into the freed renderer"
            )
            layer.display()
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
            CATransaction.flush()
            #expect(
                renderer.displayCount == countBeforeDisplay,
                "a Core Animation display after the native free reached the freed renderer"
            )
        }
    }

    /// Samples the layer's display slots from inside the native-free
    /// override, so a detach that only happens after the free still fails.
    ///
    /// `@unchecked Sendable`: the override runs on the coordinator's worker;
    /// the samples are guarded by `lock`, and the layer slots are only read.
    private final class NativeFreeDisplayProbe: @unchecked Sendable {
        private let layer: CALayer
        private let lock = NSLock()
        private var samples: [(callback: UnsafeMutableRawPointer?, context: UnsafeMutableRawPointer?)] = []

        init(layer: CALayer) {
            self.layer = layer
        }

        func sampleAtNativeFree() {
            let sample = (
                callback: FakeGhosttyIOSurfaceLayer.displayCallbackPointer(of: layer),
                context: FakeGhosttyIOSurfaceLayer.displayContextPointer(of: layer)
            )
            lock.lock()
            samples.append(sample)
            lock.unlock()
        }

        func expectDetachedAtNativeFree() {
            lock.lock()
            let samples = samples
            lock.unlock()
            #expect(samples.count == 1, "expected exactly one native free")
            for sample in samples {
                #expect(
                    sample.callback == nil,
                    "the native free began while the layer's display callback still pointed at its renderer"
                )
                #expect(
                    sample.context == nil,
                    "the native free began while the layer's display context still pointed at its renderer"
                )
            }
        }
    }

    private func installGhosttyLayer(on surface: TerminalSurface) -> GhosttyLayerFixture {
        let renderer = FakeGhosttyRenderer()
        let layer = FakeGhosttyIOSurfaceLayer.make(renderer: renderer)
        // Mirrors Ghostty's macOS presenter: assign the layer before
        // `wantsLayer` so the view becomes layer-hosting.
        let hostView: NSView = surface.surfaceView
        hostView.layer = layer
        hostView.wantsLayer = true
        return GhosttyLayerFixture(layer: layer, renderer: renderer)
    }

    private func makeSurface(
        registry: any TerminalSurfaceRegistering = FakeSurfaceRegistry()
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }

    private func fakeRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x7543)!
    }
}
