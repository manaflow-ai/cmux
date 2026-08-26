import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_realized_begin")
private func beginRendererRealizedTracking(_ surface: UnsafeMutableRawPointer)

@_silgen_name("cmux_test_ghostty_renderer_realized_reset")
private func resetRendererRealizedTracking()

@_silgen_name("cmux_test_ghostty_renderer_realized_call_count")
private func rendererRealizedCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_renderer_rebuild_call_count")
private func rendererRebuildCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_renderer_realized_call_value")
private func rendererRealizedCallValue(_ index: UInt32) -> Bool

@_silgen_name("cmux_test_ghostty_renderer_occlusion_visible")
private func rendererOcclusionVisible() -> Bool

@_silgen_name("cmux_test_ghostty_renderer_release_was_occluded")
private func rendererReleaseWasOccluded() -> Bool

/// Window-level occlusion: the visible tab of a miniaturized or fully covered
/// window must occlude the core surface, become reclaimable, and replay its
/// presentation transition when the window returns on screen.
@MainActor
@Suite(.serialized) struct TerminalSurfaceWindowOcclusionTests {
    @Test func windowHideOccludesAndUnprotectsTheRenderer() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        #expect(surface.isRendererPresented)
        #expect(rendererOcclusionVisible())
        #expect(!surface.releaseRenderer())

        surface.setRendererWindowVisible(false)

        #expect(!rendererOcclusionVisible())
        #expect(!surface.isRendererEffectivelyVisible)
        #expect(surface.isRendererPortalVisible)
        #expect(surface.releaseRenderer())
        #expect(rendererRealizedCalls() == [false])
        #expect(rendererReleaseWasOccluded())
    }

    @Test func windowShowReplaysPresentationAfterReclaim() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererWindowVisible(false)
        #expect(surface.releaseRenderer())
        #expect(!surface.isRendererPresented)

        surface.setRendererWindowVisible(true)

        #expect(surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 1)
        #expect(rendererOcclusionVisible())
    }

    @Test func windowShowWithoutReclaimJustLiftsOcclusion() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererWindowVisible(false)
        #expect(!rendererOcclusionVisible())

        surface.setRendererWindowVisible(true)

        #expect(rendererOcclusionVisible())
        #expect(surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 0)
        #expect(rendererRealizedCallCount() == 0)
    }

    @Test func hiddenWindowDefersFirstPresentationUntilShown() {
        let fixture = PresentedSurfaceFixture(windowVisibleAtCreation: false)
        defer { fixture.tearDown() }
        let surface = fixture.surface

        // A runtime created while the window is hidden normalizes into the
        // released state instead of presenting into an invisible window.
        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false])
        #expect(!rendererOcclusionVisible())

        surface.setRendererWindowVisible(true)

        #expect(surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 1)
        #expect(rendererOcclusionVisible())
    }

    @Test func portalRevealInsideHiddenWindowKeepsOcclusion() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererWindowVisible(false)
        #expect(!rendererOcclusionVisible())

        surface.applyVisibilityOcclusion(true)

        #expect(!rendererOcclusionVisible())
    }

    @Test func hiddenPortalIgnoresWindowTransitions() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        // The portal host applies occlusion alongside the visibility flip.
        surface.setRendererPortalVisible(false)
        surface.applyVisibilityOcclusion(false)
        #expect(!rendererOcclusionVisible())

        surface.setRendererWindowVisible(false)
        surface.setRendererWindowVisible(true)

        // A hidden portal stays occluded regardless of window visibility.
        #expect(!rendererOcclusionVisible())
        #expect(rendererRebuildCallCount() == 0)
    }

    private func rendererRealizedCalls() -> [Bool] {
        (0..<rendererRealizedCallCount()).map(rendererRealizedCallValue)
    }
}

/// A surface with a live runtime pointer attached to a real (test) window with
/// usable drawable geometry, presented unless the window starts hidden.
@MainActor
private struct PresentedSurfaceFixture {
    let registry: TerminalSurfaceRegistry
    let surface: TerminalSurface
    let window: NSWindow
    let runtimeSurface: UnsafeMutableRawPointer

    init(windowVisibleAtCreation: Bool = true) {
        registry = TerminalSurfaceRegistry()
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        surface = TerminalSurface(
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
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    agentCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        surface.paneHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        surface.surfaceView.frame = surface.paneHost.bounds
        window.contentView?.addSubview(surface.paneHost)
        surface.attachedView = surface.surfaceView

        runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        beginRendererRealizedTracking(runtimeSurface)
        surface.setRendererPortalVisible(true)
        if !windowVisibleAtCreation {
            surface.setRendererWindowVisible(false)
        }
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.rendererRuntimeSurfaceDidCreate()
    }

    func tearDown() {
        surface.releaseSurfaceForTesting()
        runtimeSurface.deallocate()
        resetRendererRealizedTracking()
        window.contentView = nil
        window.close()
    }
}
