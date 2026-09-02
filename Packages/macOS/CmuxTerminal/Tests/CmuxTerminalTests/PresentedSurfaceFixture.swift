import AppKit
import CmuxTerminalCore
import GhosttyKit
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_realized_begin")
private func beginRendererRealizedTracking(_ surface: UnsafeMutableRawPointer)

@_silgen_name("cmux_test_ghostty_renderer_realized_reset")
private func resetRendererRealizedTracking()

/// A surface with a live runtime pointer attached to a real (test) window with
/// usable drawable geometry, presented unless the window starts hidden.
@MainActor
struct PresentedSurfaceFixture {
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
