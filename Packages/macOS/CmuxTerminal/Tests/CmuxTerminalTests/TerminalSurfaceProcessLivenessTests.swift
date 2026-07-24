import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_runtime_stubs_reset")
private func resetGhosttyRuntimeStubs()

@_silgen_name("cmux_test_ghostty_runtime_stubs_set_process_exited")
private func setGhosttyProcessExited(_ processExited: Bool)

@MainActor
@Suite(.serialized)
struct TerminalSurfaceProcessLivenessTests {
    @Test func reportsOnlyValidatedLocalRuntimeState() {
        resetGhosttyRuntimeStubs()
        let registry = TerminalSurfaceRegistry()
        let coldSurface = makeSurface(registry: registry)
        let manualSurface = makeSurface(registry: registry, manualIO: true)

        #expect(coldSurface.processAlive() == nil)
        #expect(manualSurface.processAlive() == nil)

        let liveSurface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: liveSurface.id)
        liveSurface.installRuntimeSurfaceForTesting(runtimeSurface)
        defer {
            runtimeSurface.deallocate()
            resetGhosttyRuntimeStubs()
        }

        setGhosttyProcessExited(false)
        #expect(liveSurface.processAlive() == true)

        setGhosttyProcessExited(true)
        #expect(liveSurface.processAlive() == false)

        liveSurface.releaseSurfaceForTesting()
        #expect(liveSurface.processAlive() == nil)
    }

    private func makeSurface(
        registry: TerminalSurfaceRegistry,
        manualIO: Bool = false
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            manualIO: manualIO,
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
