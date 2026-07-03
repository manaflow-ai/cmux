import Foundation
import AppKit
import GhosttyKit
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

/// Coverage for the close-confirmation queries.
///
/// The session autosave tick used to call `needsConfirmClose()` — which takes the
/// surface's `renderer_state` mutex via `ghostty_surface_needs_confirm_quit` — on
/// the main thread for every panel. When a surface's renderer/io thread was wedged
/// holding that mutex, the main thread parked in `__ulock_wait2` forever and the
/// app beach-balled (https://github.com/manaflow-ai/cmux/issues/6381). The snapshot
/// path now uses `snapshotNeedsConfirmClose()`, which reads the lock-free
/// `ghostty_surface_process_exited` field and can never wedge.
@MainActor
@Suite struct TerminalSurfaceNeedsConfirmCloseTests {
    /// Both queries share the contract that a surface with no live runtime never
    /// needs confirmation.
    @Test func bothQueriesReturnFalseWithoutRuntimeSurface() {
        let surface = Self.makeSurface()
        #expect(surface.needsConfirmClose() == false)
        #expect(surface.snapshotNeedsConfirmClose() == false)
    }

    // MARK: - Helpers

    private static func makeSurface() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: .immediate,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: RecordingRestoreSpawnScheduler(),
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
}
