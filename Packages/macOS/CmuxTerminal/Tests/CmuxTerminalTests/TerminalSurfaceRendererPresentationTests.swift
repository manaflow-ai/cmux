import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_realized_begin")
private func beginRendererRealizedTracking(_ surface: UnsafeMutableRawPointer)

@_silgen_name("cmux_test_ghostty_renderer_realized_reset")
private func resetRendererRealizedTracking()

@_silgen_name("cmux_test_ghostty_renderer_realized_call_count")
private func rendererRealizedCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_renderer_realized_call_value")
private func rendererRealizedCallValue(_ index: UInt32) -> Bool

@_silgen_name("cmux_test_ghostty_renderer_realized_set_result")
private func setRendererRealizedResult(_ result: Bool)

@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererPresentationTests {
    @Test func hiddenRuntimeIsReleasedThenRealizedOnFirstVisibility() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(false)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate()
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        #expect(!surface.isRendererRealized)
        #expect(rendererRealizedCalls() == [false])

        surface.setRendererPortalVisible(true)

        #expect(surface.isRendererPortalVisible)
        #expect(surface.isRendererRealized)
        #expect(rendererRealizedCalls() == [false, true])

        surface.setRendererPortalVisible(true)

        #expect(rendererRealizedCalls() == [false, true])
    }

    @Test func visibleRuntimeIsPresentedWithoutRedundantNativeTransition() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate()
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        #expect(surface.isRendererPortalVisible)
        #expect(surface.isRendererRealized)
        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls().isEmpty)

        surface.setRendererPortalVisible(true)

        #expect(rendererRealizedCalls().isEmpty)
    }

    @Test func reclaimedRuntimeIsRealizedOnceWhenShownAgain() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(true)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate()
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        surface.setRendererPortalVisible(false)

        #expect(surface.releaseRenderer())
        #expect(!surface.isRendererRealized)
        #expect(rendererRealizedCalls() == [false])

        surface.setRendererPortalVisible(true)
        surface.setRendererPortalVisible(true)

        #expect(surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false, true])
    }

    @Test func failedFirstPresentationWaitsForRendererActivityBeforeSchedulingRepair() {
        let registry = TerminalSurfaceRegistry()
        let scheduler = FakeRendererRealizationScheduler()
        let surface = makeSurface(registry: registry, rendererRealization: scheduler)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        surface.setRendererPortalVisible(false)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate()
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
            resetRendererRealizedTracking()
        }

        beginRendererRealizedTracking(runtimeSurface)
        setRendererRealizedResult(false)
        surface.setRendererPortalVisible(true)

        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false])
        #expect(scheduler.scheduledPassCount == 0)
    }

    private func rendererRealizedCalls() -> [Bool] {
        (0..<rendererRealizedCallCount()).map(rendererRealizedCallValue)
    }

    private func makeSurface(
        registry: TerminalSurfaceRegistry,
        rendererRealization: any TerminalRendererRealizationScheduling = FakeRendererRealizationScheduler()
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: rendererRealization,
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }

}
