import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_runtime_stubs_reset")
private func resetGhosttyRuntimeStubs()

@_silgen_name("cmux_test_ghostty_runtime_stubs_occlusion_call_count")
private func occlusionCallCount() -> UInt64

@_silgen_name("cmux_test_ghostty_runtime_stubs_last_occlusion_surface")
private func lastOcclusionSurface() -> UInt

@_silgen_name("cmux_test_ghostty_runtime_stubs_last_occlusion_visible")
private func lastOcclusionVisible() -> Bool

@MainActor
@Suite(.serialized) struct TerminalSurfaceOcclusionTests {
    @Test func hiddenStateRequestedBeforeRuntimeCreationIsReplayedAfterCreation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        resetGhosttyRuntimeStubs()
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        surface.setOcclusion(false)
        #expect(occlusionCallCount() == 0)

        surface.installRuntimeSurfaceForTesting(runtimeSurface)

        #expect(occlusionCallCount() == 1)
        #expect(lastOcclusionSurface() == UInt(bitPattern: runtimeSurface))
        #expect(!lastOcclusionVisible())
    }

    private func makeSurface() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
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
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(
                    interSpawnDelay: .zero
                ),
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

    private func fakeRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x0CC1_0510)!
    }
}
