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
/// tick called `needsConfirmClose()` synchronously on the main thread via
/// `Workspace.sessionPanelSnapshot`; when one of those threads was wedged on the
/// lock the main thread parked in `__ulock_wait2` forever and the whole app
/// beach-balled. The fix never queries ghostty on the main thread: it returns a
/// value cached off the main thread and refreshes it in the background.
@MainActor
@Suite struct TerminalSurfaceNeedsConfirmCloseTests {
    /// The lock-taking ghostty query must run off the main thread, and its result
    /// must land in the cache `needsConfirmClose()` reads.
    @Test func refreshRunsQueryOffMainThreadAndCachesResult() async {
        let surface = Self.makeSurfaceWithFakeRuntime()

        let probeThreadWasMain = ThreadAffinityBox()
        // The probe returns `false`, the opposite of the cache's seeded default,
        // so a passing assertion proves the off-main result was actually stored.
        surface.refreshNeedsConfirmCloseCacheIfIdle(Self.fakeRuntimeSurface) { _ in
            probeThreadWasMain.value = Thread.isMainThread
            return false
        }
        await Self.waitForRefreshToSettle(surface)

        #expect(probeThreadWasMain.value == false)
        #expect(surface.needsConfirmCloseCache.value == false)
    }

    /// `needsConfirmClose()` returns the cached value synchronously — it must not
    /// run the ghostty query on the calling (main) thread — and schedules a
    /// background refresh for next time.
    @Test func needsConfirmCloseReturnsCachedValueSynchronously() {
        let surface = Self.makeSurfaceWithFakeRuntime()
        // Seed the opposite of the default so the assertion proves the value came
        // from the cache rather than the seeded default.
        surface.needsConfirmCloseCache.value = false

        #expect(surface.needsConfirmClose() == false)
        // The synchronous read kicked a background refresh that has not settled
        // yet (the main-queue store can't run until this test yields the thread).
        #expect(surface.needsConfirmCloseCache.refreshInFlight == true)
    }

    /// A wedged surface lock cannot block the main thread: while the background
    /// query is stuck, `needsConfirmClose()` keeps returning the cached value, and
    /// the in-flight guard suppresses a second probe. The cache is published once
    /// the query unblocks.
    @Test func needsConfirmCloseStaysResponsiveWhileQueryIsWedged() async {
        let surface = Self.makeSurfaceWithFakeRuntime()
        // Seed the opposite of what the wedged probe will eventually return so the
        // final assertion proves the late result was stored.
        surface.needsConfirmCloseCache.value = false

        // The probe blocks on a background thread, standing in for a renderer/io
        // thread holding the renderer lock. `wait()` here is a synchronous closure
        // off the main thread, never on the calling thread.
        let unblockProbe = DispatchSemaphore(value: 0)
        surface.refreshNeedsConfirmCloseCacheIfIdle(Self.fakeRuntimeSurface) { _ in
            unblockProbe.wait()
            return true
        }

        // The query is still wedged, yet the main thread stays responsive: it
        // returns the cached value and does not enqueue a second probe.
        #expect(surface.needsConfirmClose() == false)
        #expect(surface.needsConfirmCloseCache.refreshInFlight == true)

        unblockProbe.signal()
        await Self.waitForRefreshToSettle(surface)
        #expect(surface.needsConfirmCloseCache.value == true)
    }

    // MARK: - Helpers

    /// A non-null opaque pointer; the injected probe never dereferences it and
    /// `needsConfirmClose` only checks the pointer for existence.
    private static let fakeRuntimeSurface = ghostty_surface_t(bitPattern: 0xC0FF_EE00)!

    private static func waitForRefreshToSettle(_ surface: TerminalSurface) async {
        for _ in 0..<400 {
            if !surface.needsConfirmCloseCache.refreshInFlight { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

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
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface)
        return surface
    }
}

/// Carries a boolean recorded on a background thread back to the main thread,
/// published through a `DispatchSemaphore`/`refreshInFlight` flip (happens-before
/// the read).
private final class ThreadAffinityBox: @unchecked Sendable {
    var value = true
}
