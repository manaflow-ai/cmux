import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import os
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

private final class AgentCommandShimRemovalRecorder: Sendable {
    private let state = OSAllocatedUnfairLock<[(surfaceId: UUID, rootDirectory: URL)]>(initialState: [])

    var removals: [(surfaceId: UUID, rootDirectory: URL)] {
        state.withLock { $0 }
    }

    func record(surfaceId: UUID, rootDirectory: URL) {
        state.withLock { $0.append((surfaceId, rootDirectory)) }
    }
}

@MainActor
@Suite
struct TerminalSurfaceAgentCommandShimLifecycleTests {
    @Test
    func permanentCloseRemovesTheSurfaceShims() async {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let rootDirectory = URL(fileURLWithPath: "/tmp/cmux-agent-shim-close-tests", isDirectory: true)
        let recorder = AgentCommandShimRemovalRecorder()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: rootDirectory,
            installAgentCommandShims: { _, surfaceId, rootDirectory, _ in
                TerminalSurfaceAgentCommandShimSet(
                    directoryPath: rootDirectory
                        .appendingPathComponent("cmux-cli-shims/\(surfaceId.uuidString)").path,
                    shims: []
                )
            },
            isExecutableFile: { _ in false },
            removeAgentCommandShims: { recorder.record(surfaceId: $0, rootDirectory: $1) }
        )
        let surface = makeSurface(
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem
        )
        _ = surface.agentCommandShimStateForSurface(view: nativeView, source: .inputDemand)
        _ = await surface.agentCommandShimInstallTask?.value
        _ = await surface.agentCommandShimCompletionTask?.value
        #expect(surface.agentCommandShims != nil)

        surface.removeAgentCommandShimsForPermanentClose()

        #expect(recorder.removals.map(\.surfaceId) == [surface.id])
        #expect(recorder.removals.map(\.rootDirectory) == [rootDirectory])
        // A pane reopened under the same surface must install again.
        #expect(surface.agentCommandShims == nil)
        let reopened = surface.agentCommandShimStateForSurface(view: nativeView, source: .inputDemand)
        #expect(!reopened.isReady)
        _ = await surface.agentCommandShimInstallTask?.value
        _ = await surface.agentCommandShimCompletionTask?.value
    }

    @Test
    func permanentCloseLeavesAnInstallStillRunningToTheSweep() async {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let probe = AgentCommandShimInstallProbe()
        let recorder = AgentCommandShimRemovalRecorder()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(
                fileURLWithPath: "/tmp/cmux-agent-shim-close-tests",
                isDirectory: true
            ),
            installAgentCommandShims: { _, _, _, _ in
                await probe.install()
                return nil
            },
            isExecutableFile: { _ in false },
            removeAgentCommandShims: { recorder.record(surfaceId: $0, rootDirectory: $1) }
        )
        let surface = makeSurface(
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem
        )
        _ = surface.agentCommandShimStateForSurface(view: nativeView, source: .inputDemand)
        await probe.waitForInstallationCount(1)
        let installTask = surface.agentCommandShimInstallTask

        // Removing now would lose to the install, which writes the directory
        // when it finishes.
        surface.removeAgentCommandShimsForPermanentClose()

        #expect(recorder.removals.isEmpty)
        await probe.releaseAll()
        _ = await installTask?.value
        _ = await surface.agentCommandShimCompletionTask?.value
    }

    @Test(arguments: [TerminalSurfaceIOMode.manual, .manualMirror])
    func permanentCloseOfAManualSurfaceRemovesNothing(mode: TerminalSurfaceIOMode) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let recorder = AgentCommandShimRemovalRecorder()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-unused-manual-shims"),
            installAgentCommandShims: { _, _, _, _ in nil },
            isExecutableFile: { _ in false },
            removeAgentCommandShims: { recorder.record(surfaceId: $0, rootDirectory: $1) }
        )
        let surface = makeSurface(
            nativeView: nativeView, paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem, ioMode: mode
        )

        surface.removeAgentCommandShimsForPermanentClose()

        #expect(recorder.removals.isEmpty)
    }

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
