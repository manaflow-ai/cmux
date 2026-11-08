import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

private actor AgentCommandShimSelectionProbe {
    private var selection: Set<TerminalSurfaceAgentCommand>?

    func record(_ selection: Set<TerminalSurfaceAgentCommand>) {
        self.selection = selection
    }

    func value() -> Set<TerminalSurfaceAgentCommand>? {
        selection
    }
}

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
            agentCommandShimRootDirectory: URL(
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

    @Test
    func claudeShimSelectionUsesTheCapturedSpawnPolicy() async {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let probe = AgentCommandShimSelectionProbe()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(
                fileURLWithPath: "/tmp/cmux-agent-shim-policy-tests",
                isDirectory: true
            ),
            installAgentCommandShims: { _, _, _, enabledCommands in
                await probe.record(enabledCommands)
                return nil
            },
            isExecutableFile: { _ in false }
        )
        let surface = makeSurface(
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem
        )
        let disabledPolicy = TerminalSurfaceSpawnPolicy(
            claudeHooksEnabled: false,
            customClaudePath: nil,
            subagentNotificationEnvironmentKey: "CMUX_TEST_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            suppressSubagentNotifications: false,
            cursorHooksEnabled: true,
            geminiHooksEnabled: true,
            kiroHooksEnabled: true,
            kiroNotificationLevel: "all",
            ampHooksEnabled: true,
            shellIntegrationEnabled: false,
            watchGitStatusEnabled: false,
            showPullRequestsEnabled: false
        )

        let initial = surface.agentCommandShimStateForSurface(
            view: nativeView,
            source: .inputDemand,
            spawnPolicy: disabledPolicy
        )
        #expect(!initial.isReady)

        _ = await surface.agentCommandShimInstallTask?.value
        _ = await surface.agentCommandShimCompletionTask?.value

        let selection = await probe.value()
        #expect(selection == disabledPolicy.enabledAgentCommandShims)
        #expect(selection?.contains(.claude) == false)
        #expect(selection?.contains(.codex) == true)
        #expect(surface.agentCommandShimSpawnPolicy?.claudeHooksEnabled == false)

        // The fixture provider returns Claude enabled. A later readiness read
        // must retain the policy paired with the completed shim generation.
        let resumed = surface.agentCommandShimStateForSurface(
            view: nativeView,
            source: .inputDemand
        )
        #expect(resumed.isReady)
        #expect(surface.agentCommandShimSpawnPolicy?.claudeHooksEnabled == false)
    }

    @Test(arguments: [TerminalSurfaceIOMode.manual, .manualMirror])
    func manualSurfaceIsReadyWithoutInstallingLocalCommandShims(mode: TerminalSurfaceIOMode) async {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-unused-manual-shims"),
            installAgentCommandShims: { _, _, _ in
                Issue.record("A manual surface has no local child process and must not install command shims")
                return nil
            },
            isExecutableFile: { _ in false }
        )
        let surface = makeSurface(
            nativeView: nativeView, paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem, ioMode: mode
        )
        let readiness = surface.agentCommandShimStateForSurface(view: nativeView, source: .inputDemand)
        #expect(readiness.isReady)
        #expect(readiness.shims == nil)
        #expect(surface.agentCommandShimInstallTask == nil)
        #expect(surface.agentCommandShimCompletionTask == nil)
        #expect(surface.agentCommandShimDeadlineTask == nil)
        // Drain a regressed installer so it cannot outlive its test case.
        _ = await surface.agentCommandShimInstallTask?.value
        _ = await surface.agentCommandShimCompletionTask?.value
    }

    private func makeSurface(
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        ioMode: TerminalSurfaceIOMode = .exec
    ) -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            ioMode: ioMode,
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
