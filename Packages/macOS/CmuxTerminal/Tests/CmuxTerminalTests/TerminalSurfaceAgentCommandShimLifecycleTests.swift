import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite
struct TerminalSurfaceAgentCommandShimLifecycleTests {
    @Test
    func cancellationKeepsOneInstallerRegisteredUntilCompletion() async {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let probe = AgentCommandShimInstallProbe()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(
                fileURLWithPath: "/tmp/cmux-agent-shim-lifecycle-tests",
                isDirectory: true
            ),
            installAgentCommandShims: { _, _, _ in
                await probe.install()
                return nil
            },
            isExecutableFile: { _ in false }
        )
        let surface = makeSurface(
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem
        )

        let initial = surface.agentCommandShimStateForSurface(
            view: nativeView,
            source: .scheduledRestore
        )
        #expect(!initial.isReady)
        await probe.waitForInstallationCount(1)
        let firstInstallTask = surface.agentCommandShimInstallTask

        surface.cancelAgentCommandShimInstallLifecycle()
        let retainedInstaller = surface.agentCommandShimInstallTask != nil
        let resumed = surface.agentCommandShimStateForSurface(
            view: nativeView,
            source: .inputDemand
        )
        #expect(!resumed.isReady)

        if !retainedInstaller {
            await probe.waitForInstallationCount(2)
        }
        let installationCount = await probe.count()
        let activeInstallTask = surface.agentCommandShimInstallTask

        #expect(retainedInstaller)
        #expect(installationCount == 1)

        await probe.releaseAll()
        _ = await firstInstallTask?.value
        _ = await activeInstallTask?.value
        _ = await surface.agentCommandShimCompletionTask?.value
    }

    private func makeSurface(
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    ) -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: .pacedSessionRestore,
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
                restoreSpawnScheduler: RecordingRestoreSpawnScheduler(),
                runtimeFilesystem: runtimeFilesystem,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}
