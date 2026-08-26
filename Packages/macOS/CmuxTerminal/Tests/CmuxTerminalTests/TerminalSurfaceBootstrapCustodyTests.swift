import Foundation
import AppKit
import GhosttyKit
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

// Regression coverage for issue #9769: after a CLI dispatch burst, new
// terminal surfaces never acquired a PTY. Two silent one-shot drops in the
// cold-start path caused it:
//
// 1. Window-portal churn (`TerminalWindowPortal.detachHostedView` →
//    `removeFromSuperview`) can park the pane host outside any window while
//    the surface still records its hidden bootstrap startup window. The next
//    runtime start then early-returns in `ensureHeadlessStartupWindowIfNeeded`
//    (a bootstrap window exists) and the follow-up attach defers on the
//    missing window — permanently, because nothing ever re-arms the start.
// 2. The optional agent command-shim install gates `createSurface`; when the
//    install task never completes, PTY spawn is starved forever.
@MainActor
@Suite struct TerminalSurfaceBootstrapCustodyTests {
    @Test func inputDemandStartReclaimsPaneHostParkedOutsideAnyWindow() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(scheduler: scheduler, nativeView: nativeView, paneHost: paneHost)
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        // A first bootstrap start records the hidden startup window and
        // attempts runtime creation. The fake engine has no runtime app, so
        // the surface stays cold — like a spawn pending behind engine startup.
        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-first-start", source: .inputDemand)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(paneHost.window != nil)

        // Window-portal churn reparents the pane host away from the bootstrap
        // window and parks it with no superview and no window.
        paneHost.removeFromSuperview()
        #expect(paneHost.window == nil)

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-post-park", source: .inputDemand)

        #expect(
            surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 2,
            "An input-demand start after portal churn parked the pane host must still attempt runtime creation (#9769)."
        )
        #expect(
            paneHost.window != nil,
            "The bootstrap start must reclaim the parked pane host into a window so libghostty can spawn (#9769)."
        )
    }

    @Test func queuedSendToParkedPaneHostStillAttemptsRuntimeStart() async {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(scheduler: scheduler, nativeView: nativeView, paneHost: paneHost)
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-first-start", source: .inputDemand)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        paneHost.removeFromSuperview()

        // `cmux send` to the cold surface: the text queues and requests an
        // input-demand start. The queued bytes must not be stranded behind a
        // parked pane host — the spawn attempt has to happen so the pending
        // input can flush once the runtime exists.
        #expect(surface.sendText("echo issue9769\n"))

        await waitForCreateAttemptCount(surface, 2)
    }

    @Test func backgroundPrimeStartToParkedPaneHostStillAttemptsRuntimeStart() async {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(scheduler: scheduler, nativeView: nativeView, paneHost: paneHost)
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-first-start", source: .inputDemand)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        paneHost.removeFromSuperview()

        // The background workspace prime coordinator re-requests cold starts
        // through this entry point; it must not be droppable either.
        surface.requestBackgroundSurfaceStartIfNeeded()

        await waitForCreateAttemptCount(surface, 2)
    }

    @Test func hungAgentShimInstallDoesNotStarveRuntimeSpawn() async throws {
        _ = try #require(Bundle.main.resourceURL)
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let shimInstaller = ManualAgentCommandShimInstaller()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: {
                await shimInstaller.install(wrapperDirectoryURL: $0, surfaceId: $1, temporaryDirectory: $2)
            },
            isExecutableFile: { _ in false }
        )
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem,
            agentCommandShimInstallDeadline: .milliseconds(100)
        )
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-shim-hang", source: .inputDemand)
        await shimInstaller.waitForInstallStart()
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)

        // The wrapper shim is an optional PATH convenience. When its install
        // task never completes (disk pressure, starved queues), PTY spawn must
        // still proceed without it instead of waiting forever (#9769).
        await waitForCreateAttemptCount(surface, 1)

        // A deadline-released spawn must not lock the surface into shim-less
        // mode: after the lifecycle cancels the hung install (teardown,
        // agent-hibernation suspend), the next runtime creation attempts a
        // fresh install instead of permanently reporting ready-without-shim.
        surface.cancelAgentCommandShimInstallLifecycle()
        let regatedState = surface.agentCommandShimStateForSurface(view: nativeView, source: .inputDemand)
        #expect(!regatedState.isReady)

        // Resume the parked install continuations so teardown stays clean.
        await shimInstaller.complete()
    }

    private func waitForCreateAttemptCount(
        _ surface: TerminalSurface,
        _ count: Int,
        iterations: Int = 400
    ) async {
        for _ in 0..<iterations {
            if surface.debugRuntimeSurfaceCreateAttemptCountForTesting() >= count { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let attempts = surface.debugRuntimeSurfaceCreateAttemptCountForTesting()
        Issue.record("Timed out waiting for \(count) runtime surface create attempt(s); got \(attempts)")
    }

    private func makeSurface(
        scheduler: RecordingRestoreSpawnScheduler,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost,
        engine: FakeTerminalEngine = FakeTerminalEngine(),
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: { _, _, _ in nil },
            isExecutableFile: { _ in false }
        ),
        agentCommandShimInstallDeadline: Duration = .seconds(5)
    ) -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: .immediate,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: engine,
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: scheduler,
                runtimeFilesystem: runtimeFilesystem,
                agentCommandShimInstallDeadline: agentCommandShimInstallDeadline,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}
