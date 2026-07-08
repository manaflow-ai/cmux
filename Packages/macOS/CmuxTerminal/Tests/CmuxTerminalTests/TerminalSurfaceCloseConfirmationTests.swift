import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_runtime_stubs_reset")
private func resetGhosttyRuntimeStubs()

@_silgen_name("cmux_test_ghostty_runtime_stubs_set_close_state")
private func setGhosttyCloseState(_ needsConfirm: Bool, _ foregroundPID: UInt64, _ ttyName: UnsafePointer<CChar>?)

@MainActor
@Suite(.serialized) struct TerminalSurfaceCloseConfirmationTests {
    @Test func liveSurfaceWithoutPidOrTtyDoesNotRequireConfirmation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        setGhosttyCloseState(true, 0, nil)
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        #expect(!surface.needsConfirmClose())
    }

    @Test func liveSurfaceWithForegroundPidPreservesGhosttyConfirmation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        setGhosttyCloseState(true, 42, nil)
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        #expect(surface.needsConfirmClose())
    }

    @Test func liveSurfaceWithTtyPreservesGhosttyConfirmation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        "/dev/ttys123".withCString { ttyName in
            setGhosttyCloseState(true, 0, ttyName)
            #expect(surface.needsConfirmClose())
        }
        resetGhosttyRuntimeStubs()
        surface.releaseSurfaceForTesting()
    }

    @Test func pendingStartupCommandPreservesGhosttyConfirmationBeforePidOrTty() {
        let surface = makeSurface(initialCommand: "sleep 10")
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        setGhosttyCloseState(true, 0, nil)
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        #expect(surface.needsConfirmClose())
    }

    private func makeSurface(initialCommand: String? = nil) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialCommand: initialCommand,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
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
        UnsafeMutableRawPointer(bitPattern: 0x7540)!
    }
}
