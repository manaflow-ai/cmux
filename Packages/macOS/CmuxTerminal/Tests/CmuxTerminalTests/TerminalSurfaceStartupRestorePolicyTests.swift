import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite
struct TerminalSurfaceStartupRestorePolicyTests {
    @Test("Explicit startup work suppresses shell defaults without suppressing cwd defaults")
    func explicitStartupWorkKeepsWorkingDirectoryDefaultsEligible() {
        let policy = TerminalSurfaceRuntimeSpawnPolicy.immediate
            .withoutDeclarativeStartupDefaults()

        #expect(!policy.allowsDeclarativeStartupDefaults)
        #expect(policy.allowsDeclarativeWorkingDirectoryDefaults)
    }

    @Test("Restore and external transactions suppress both declarative default families")
    func restoredSurfaceSuppressesBothDefaultFamilies() {
        let policy = TerminalSurfaceRuntimeSpawnPolicy.immediate
            .forRestoredSurface()

        #expect(!policy.allowsDeclarativeStartupDefaults)
        #expect(!policy.allowsDeclarativeWorkingDirectoryDefaults)
    }

    @Test("Working-directory opt-out preserves an independently selected shell policy")
    func workingDirectoryOptOutDoesNotChangeShellPolicy() {
        let policy = TerminalSurfaceRuntimeSpawnPolicy.immediate
            .withoutDeclarativeWorkingDirectoryDefaults()

        #expect(policy.allowsDeclarativeStartupDefaults)
        #expect(!policy.allowsDeclarativeWorkingDirectoryDefaults)
    }

    @Test("Creation intent resolves each declarative default family independently")
    func creationIntentResolvesIndependentDefaultFamilies() {
        let explicitStartup = TerminalSurfaceRuntimeSpawnPolicy.immediate
            .resolvingDeclarativeDefaults(
                isRestoredSurface: false,
                hasExplicitStartupWork: true,
                hasExternallyManagedWorkingDirectory: false
            )
        #expect(!explicitStartup.allowsDeclarativeStartupDefaults)
        #expect(explicitStartup.allowsDeclarativeWorkingDirectoryDefaults)

        let externallyManagedWorkingDirectory = TerminalSurfaceRuntimeSpawnPolicy.immediate
            .resolvingDeclarativeDefaults(
                isRestoredSurface: false,
                hasExplicitStartupWork: false,
                hasExternallyManagedWorkingDirectory: true
            )
        #expect(externallyManagedWorkingDirectory.allowsDeclarativeStartupDefaults)
        #expect(!externallyManagedWorkingDirectory.allowsDeclarativeWorkingDirectoryDefaults)
    }

    @Test("Restore intent fails closed even without explicit startup work")
    func restoreIntentSuppressesAllDeclarativeDefaults() {
        let policy = TerminalSurfaceRuntimeSpawnPolicy.immediate
            .resolvingDeclarativeDefaults(
                isRestoredSurface: true,
                hasExplicitStartupWork: false,
                hasExternallyManagedWorkingDirectory: false
            )

        #expect(!policy.allowsDeclarativeStartupDefaults)
        #expect(!policy.allowsDeclarativeWorkingDirectoryDefaults)
    }

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
        )
    }
}
