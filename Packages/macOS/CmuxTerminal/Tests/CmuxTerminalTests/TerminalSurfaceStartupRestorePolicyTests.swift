import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite
struct TerminalSurfaceStartupRestorePolicyTests {
    @Test("Restore admission composes with relaunch spawn pacing")
    func admissionPreservesRestorePacing() {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            policy: .pacedSessionRestore.requiringStartupRestoreAdmission(),
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "before-topology-admission")
        surface.createSurface(for: nativeView, source: .inputDemand)

        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(scheduler.scheduledSurfaceIds.isEmpty)

        surface.admitStartupRestoreRuntime()

        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(scheduler.scheduledSurfaceIds == [surface.id])

        surface.admitStartupRestoreRuntime()
        #expect(scheduler.scheduledSurfaceIds == [surface.id])

        scheduler.runScheduledOperation()
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
    }

    @Test("Explicit input cancels a deferred agent resume before admission")
    func explicitInputCancelsDeferredAgentResumeBeforeAdmission() {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: "resume codex session\n",
            runtimeSpawnPolicy: .pacedSessionRestore
                .requiringDeferredAgentResumeAdmission(),
            dependencies: makeDependencies(
                scheduler: scheduler,
                nativeView: nativeView,
                paneHost: paneHost
            )
        )
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        var cancellationCount = 0
        surface.onStartupRestoreAdmissionCancelled = { cancellationCount += 1 }
        surface.didReceiveExplicitInput()

        #expect(cancellationCount == 1)
        #expect(surface.suppressConfiguredInitialInput)
        #expect(!surface.admitStartupRestoreRuntime(initialInput: "late resume\n"))
        #expect(scheduler.scheduledSurfaceIds == [surface.id])
    }

    private func makeSurface(
        policy: TerminalSurfaceRuntimeSpawnPolicy,
        scheduler: RecordingRestoreSpawnScheduler,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost
    ) -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: policy,
            dependencies: makeDependencies(
                scheduler: scheduler,
                nativeView: nativeView,
                paneHost: paneHost
            )
        )
    }

    private func makeDependencies(
        scheduler: RecordingRestoreSpawnScheduler,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost
    ) -> TerminalSurfaceRuntimeDependencies {
        TerminalSurfaceRuntimeDependencies(
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
                restoreSpawnScheduler: scheduler,
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
    }
}
