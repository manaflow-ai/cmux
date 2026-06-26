import Foundation
import AppKit
import GhosttyKit
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

/// Regression coverage for the main-thread deadlock in the session autosave
/// tick (https://github.com/manaflow-ai/cmux/issues/6381).
///
/// `ghostty_surface_needs_confirm_quit` takes the surface's `renderer_state`
/// mutex, which is also held by the surface's renderer/io threads. The autosave
/// tick calls `needsConfirmClose()` synchronously on the main thread via
/// `Workspace.sessionPanelSnapshot`; when one of those threads is wedged on the
/// lock the main thread parks in `__ulock_wait2` forever and the whole app
/// beach-balls. The fix runs the query off the main thread with a bounded
/// timeout so a wedged surface can never hang the app.
@MainActor
@Suite struct TerminalSurfaceNeedsConfirmCloseTests {
    /// A wedged surface lock must never block the main thread: `needsConfirmClose`
    /// has to time out and fall back to `false` instead of waiting forever.
    @Test func needsConfirmCloseTimesOutInsteadOfBlockingMainThreadOnWedgedLock() {
        let surface = Self.makeSurfaceWithFakeRuntime()
        defer { TerminalSurface.needsConfirmQuitProbeForTesting = nil }

        // Simulate a renderer/io thread holding `renderer_state.mutex`: the query
        // can't return until well past the main-thread timeout window.
        let probeCompleted = DispatchSemaphore(value: 0)
        TerminalSurface.needsConfirmQuitProbeForTesting = { _ in
            Thread.sleep(forTimeInterval: 1.5)
            probeCompleted.signal()
            return true
        }

        // Without the fix this blocks the main thread for the full 1.5s and
        // returns `true`; with the fix it times out quickly and returns `false`.
        let result = surface.needsConfirmClose()
        #expect(result == false)

        // Let the leaked probe drain before clearing the seam so it can't run
        // against a torn-down suite.
        _ = probeCompleted.wait(timeout: .now() + 5)
    }

    /// The lock-taking ghostty query must run off the main thread.
    @Test func needsConfirmCloseRunsGhosttyQueryOffMainThread() {
        let surface = Self.makeSurfaceWithFakeRuntime()
        defer { TerminalSurface.needsConfirmQuitProbeForTesting = nil }

        let probeRanOnMainThread = ThreadAffinityBox()
        let probeFinished = DispatchSemaphore(value: 0)
        TerminalSurface.needsConfirmQuitProbeForTesting = { _ in
            probeRanOnMainThread.value = Thread.isMainThread
            probeFinished.signal()
            return true
        }

        let result = surface.needsConfirmClose()
        _ = probeFinished.wait(timeout: .now() + 5)

        // Without the fix the query runs synchronously on the calling (main)
        // thread; with the fix it is dispatched to a background queue.
        #expect(probeRanOnMainThread.value == false)
        // The real answer is still plumbed back when the query returns promptly.
        #expect(result == true)
    }

    // MARK: - Helpers

    private static func makeSurfaceWithFakeRuntime() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let surface = TerminalSurface(
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
        // A non-null opaque pointer is enough: the probe seam never dereferences
        // it, and `needsConfirmClose` only checks the pointer for existence.
        let fakeRuntimeSurface = ghostty_surface_t(bitPattern: 0xC0FF_EE00)!
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface)
        return surface
    }
}

/// Carries a boolean recorded on a background thread back to the main thread,
/// published through a `DispatchSemaphore` (happens-before the read).
private final class ThreadAffinityBox: @unchecked Sendable {
    var value = true
}
