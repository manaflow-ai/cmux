import Foundation
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

@Suite(.serialized) @MainActor
struct TerminalSurfaceOcclusionTests {
    init() {
        cmux_test_ghostty_runtime_stubs_reset()
    }

    @Test func hiddenIntentBeforeCreationIsAppliedWhenRuntimeAppears() throws {
        let surface = makeSurface()

        surface.setOcclusion(false)
        #expect(cmux_test_ghostty_surface_set_occlusion_call_count() == 0)

        surface.installRuntimeSurfaceForTesting(
            try #require(ghostty_surface_t(bitPattern: 0x1))
        )

        #expect(cmux_test_ghostty_surface_set_occlusion_call_count() == 1)
        #expect(!cmux_test_ghostty_surface_last_occlusion_visible())
    }

    @Test func hiddenIntentSurvivesRuntimeRecreationAndDeduplicatesWithinOneRuntime() throws {
        let surface = makeSurface()
        surface.setOcclusion(false)

        surface.installRuntimeSurfaceForTesting(
            try #require(ghostty_surface_t(bitPattern: 0x1))
        )
        surface.setOcclusion(false)
        #expect(cmux_test_ghostty_surface_set_occlusion_call_count() == 1)

        surface.installRuntimeSurfaceForTesting(
            try #require(ghostty_surface_t(bitPattern: 0x2))
        )

        #expect(cmux_test_ghostty_surface_set_occlusion_call_count() == 2)
        #expect(!cmux_test_ghostty_surface_last_occlusion_visible())
    }

    private func makeSurface() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView()
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: FakeTerminalSurfacePaneHost(surfaceView: nativeView)
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: RecordingRestoreSpawnScheduler(),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests"),
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
