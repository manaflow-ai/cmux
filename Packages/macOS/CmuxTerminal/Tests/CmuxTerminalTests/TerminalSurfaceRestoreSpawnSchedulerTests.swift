import Foundation
import AppKit
import GhosttyKit
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@MainActor
@Suite struct TerminalSurfaceRestoreSpawnSchedulerTests {
    @Test func restoredSurfaceSpawnsDrainOnePerDelay() async {
        let delayer = ManualRestoreSpawnDelayer()
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(
            interSpawnDelay: .milliseconds(125),
            delayer: delayer
        )
        let ids = (0..<3).map { _ in UUID() }
        var spawned: [UUID] = []

        for id in ids {
            scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
                spawned.append(id)
            }
        }

        await delayer.waitForDelayCount(1)
        #expect(spawned == [ids[0]])

        delayer.releaseNextDelay()
        await delayer.waitForDelayCount(2)
        #expect(spawned == [ids[0], ids[1]])

        delayer.releaseNextDelay()
        await waitForSpawnCount(3, spawned: { spawned.count })
        #expect(spawned == ids)
    }

    @Test func twelveRestoredSurfaceBurstDrainsOneNativeSpawnPerCadence() async {
        let delayer = ManualRestoreSpawnDelayer()
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(
            interSpawnDelay: .milliseconds(125),
            delayer: delayer
        )
        let ids = (0..<12).map { _ in UUID() }
        var spawned: [UUID] = []

        for id in ids {
            scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
                spawned.append(id)
            }
        }

        await delayer.waitForDelayCount(1)
        #expect(spawned == [ids[0]])

        for expectedSpawnCount in 2...ids.count {
            delayer.releaseNextDelay()
            await waitForSpawnCount(expectedSpawnCount, spawned: { spawned.count })
            #expect(spawned == Array(ids.prefix(expectedSpawnCount)))
        }

        #expect(spawned == ids)
    }

    @Test func duplicateReadinessCallbacksForOneSurfaceCoalesce() async {
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero)
        let id = UUID()
        var spawned: [String] = []

        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
            spawned.append("first")
        }
        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
            spawned.append("duplicate")
        }

        await waitForSpawnCount(1, spawned: { spawned.count })
        #expect(spawned == ["first"])
    }

    @Test func laterReadinessDuringCooldownStillWaitsForDelay() async {
        let delayer = ManualRestoreSpawnDelayer()
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(
            interSpawnDelay: .milliseconds(125),
            delayer: delayer
        )
        let ids = (0..<2).map { _ in UUID() }
        var spawned: [UUID] = []

        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: ids[0]) {
            spawned.append(ids[0])
        }

        await delayer.waitForDelayCount(1)
        #expect(spawned == [ids[0]])

        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: ids[1]) {
            spawned.append(ids[1])
        }

        #expect(spawned == [ids[0]])

        delayer.releaseNextDelay()
        await waitForSpawnCount(2, spawned: { spawned.count })
        #expect(spawned == ids)
    }

    @Test func restorePacedTerminalSurfaceQueuesNativeCreationBeforeGhosttyWork() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(scheduler: scheduler, nativeView: nativeView, paneHost: paneHost)
        surface.claudeCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func restorePacedTerminalSurfaceWaitsForClaudeShimBeforeEnteringSpawnQueue() async throws {
        _ = try #require(Bundle.main.resourceURL)
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let shimInstaller = ManualClaudeCommandShimInstaller()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installClaudeCommandShim: {
                await shimInstaller.install(wrapperURL: $0, surfaceId: $1, temporaryDirectory: $2)
            },
            isExecutableFile: { _ in false }
        )
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem
        )
        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-shim-gate")
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.createSurface(for: nativeView)
        await shimInstaller.waitForInstallStart()

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)

        await shimInstaller.complete()
        await waitForSpawnCount(1, spawned: { scheduler.scheduledSurfaceIds.count })

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
    }

    @Test func scheduledRestoreCreationCanRequeueWhenTheViewIsNotReady() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        scheduler.runScheduledOperation()
        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds == [surface.id, surface.id])
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func immediateTerminalSurfaceBypassesRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .immediate,
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func inputDemandForRestorePacedTerminalBypassesPendingRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        surface.createSurface(for: nativeView, source: .inputDemand)

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func postShimScheduledRestoreDoesNotTailAppendReadyViewToRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-ready-slot")
        defer { surface.closeHeadlessStartupWindowIfNeeded() }
        surface.attachedView = nativeView
        surface.claudeCommandShimInstallCompleted = true

        #expect(nativeView.window != nil)
        surface.resumeSurfaceCreationAfterClaudeCommandShimReady(
            view: nativeView,
            source: .scheduledRestore
        )

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func postShimScheduledRestoreWithoutReadyViewDoesNotTailAppendToRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallCompleted = true

        surface.resumeSurfaceCreationAfterClaudeCommandShimReady(
            view: nativeView,
            source: .scheduledRestore
        )

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func queuedSocketInputPromotesBackgroundStartToInputDemand() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.backgroundSurfaceStartQueued = true
        surface.backgroundSurfaceStartSource = .normal

        #expect(surface.sendText("echo queued\n"))

        #expect(surface.backgroundSurfaceStartQueued)
        #expect(surface.backgroundSurfaceStartSource == .inputDemand)
        #expect(scheduler.scheduledSurfaceIds.isEmpty)
    }

    @Test func inputDemandHeadlessStartDoesNotQueueRestoreSpawnThroughPaneHostAttach() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-input-demand", source: .inputDemand)

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func inputDemandPromotesInFlightClaudeShimCreationSource() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallTask = Task { nil }
        defer {
            surface.claudeCommandShimInstallTask?.cancel()
            surface.claudeCommandShimInstallTask = nil
            surface.claudeCommandShimPendingCreationSource = nil
        }

        _ = surface.claudeCommandShimStateForSurface(view: nativeView, source: .scheduledRestore)
        _ = surface.claudeCommandShimStateForSurface(view: nativeView, source: .inputDemand)

        #expect(surface.claudeCommandShimPendingCreationSource == .inputDemand)
    }

    @Test func inputDemandShimFallbackStartsHeadlessWithoutRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.claudeCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.resumeSurfaceCreationAfterClaudeCommandShimReady(
            view: nil,
            source: .inputDemand
        )

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    private func waitForSpawnCount(_ count: Int, spawned: () -> Int) async {
        for _ in 0..<100 {
            if spawned() >= count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) scheduled restored surface spawns")
    }

    private func makeSurface(
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .pacedSessionRestore,
        scheduler: RecordingRestoreSpawnScheduler,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installClaudeCommandShim: { _, _, _ in nil },
            isExecutableFile: { _ in false }
        )
    ) -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: scheduler,
                runtimeFilesystem: runtimeFilesystem,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}
