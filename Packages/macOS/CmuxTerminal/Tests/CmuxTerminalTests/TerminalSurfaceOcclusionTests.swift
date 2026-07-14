import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_runtime_stubs_reset_occlusion")
private func resetOcclusionStubs()

@_silgen_name("cmux_test_ghostty_runtime_stubs_occlusion_call_count")
private func occlusionCallCount() -> UInt64

@_silgen_name("cmux_test_ghostty_runtime_stubs_last_occlusion_surface")
private func lastOcclusionSurface() -> UInt

@_silgen_name("cmux_test_ghostty_runtime_stubs_last_occlusion_visible")
private func lastOcclusionVisible() -> Bool

@_silgen_name("cmux_test_ghostty_runtime_stubs_last_occlusion_sequence")
private func lastOcclusionSequence() -> UInt64

@_silgen_name("cmux_test_ghostty_runtime_stubs_last_refresh_sequence")
private func lastRefreshSequence() -> UInt64

@MainActor
@Suite(.serialized) struct TerminalSurfaceOcclusionTests {
    @Test func hiddenStateRequestedBeforeRuntimeCreationIsReplayedBeforeRefresh() throws {
        let surfaceID = UUID()
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let surface = makeSurface(id: surfaceID, nativeView: nativeView)
        resetOcclusionStubs()
        defer {
            surface.releaseSurfaceForTesting()
            resetOcclusionStubs()
        }

        surface.setOcclusion(false)
        #expect(occlusionCallCount() == 0)

        surface.claudeCommandShimInstallCompleted = true
        surface.createSurface(for: nativeView, source: .normal)
        let runtimeSurface = try #require(surface.surface)

        #expect(occlusionCallCount() == 1)
        #expect(lastOcclusionSurface() == UInt(bitPattern: runtimeSurface))
        #expect(!lastOcclusionVisible())
        #expect(lastOcclusionSequence() > 0)
        #expect(lastRefreshSequence() > lastOcclusionSequence())
    }

    private func makeSurface(
        id: UUID,
        nativeView: FakeTerminalSurfaceNativeView
    ) -> TerminalSurface {
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            id: id,
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: OcclusionTestSurfaceRegistry(ownerID: id),
                engine: OcclusionTestTerminalEngine(),
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
}

@MainActor
private final class OcclusionTestTerminalEngine: TerminalEngineHosting {
    let runtimeApp: ghostty_app_t? = UnsafeMutableRawPointer(bitPattern: 0x0CC1_0510)
    let runtimeConfig: ghostty_config_t? = nil
    let userGhosttyShellIntegrationMode = "none"
}

private final class OcclusionTestSurfaceRegistry: TerminalSurfaceRegistering {
    let ownerID: UUID

    init(ownerID: UUID) {
        self.ownerID = ownerID
    }

    func register(_ surface: any TerminalSurfacing) {}
    func unregister(_ surface: any TerminalSurfacing) {}
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {}
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {}
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? { ownerID }
    func surface(id: UUID) -> (any TerminalSurfacing)? { nil }
    func isRightSidebarDockSurface(id: UUID) -> Bool { false }
    func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {}
    func allSurfaces() -> [any TerminalSurfacing] { [] }
}
