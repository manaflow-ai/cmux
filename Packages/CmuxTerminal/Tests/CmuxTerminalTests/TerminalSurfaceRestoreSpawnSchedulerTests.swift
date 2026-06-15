import Foundation
import AppKit
import GhosttyKit
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@MainActor
private final class ManualRestoreSpawnDelayer: TerminalSurfaceRestoreSpawnDelaying {
    private var delayCount = 0
    private var delayOperations: [@MainActor () -> Void] = []
    private var delayOperationHead = 0
    private var countContinuations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func scheduleDelay(
        for duration: Duration,
        operation: @escaping @MainActor () -> Void
    ) -> any TerminalSurfaceRestoreSpawnDelayCancelling {
        _ = duration
        delayCount += 1
        let count = delayCount
        for waiter in countContinuations.removeValue(forKey: count) ?? [] {
            waiter.resume()
        }
        delayOperations.append(operation)
        return ManualRestoreSpawnDelay()
    }

    func waitForDelayCount(_ count: Int) async {
        guard delayCount < count else { return }
        await withCheckedContinuation { continuation in
            countContinuations[count, default: []].append(continuation)
        }
    }

    func releaseNextDelay() {
        guard delayOperationHead < delayOperations.count else { return }
        let operation = delayOperations[delayOperationHead]
        delayOperationHead += 1
        operation()
    }
}

@MainActor
private final class ManualRestoreSpawnDelay: TerminalSurfaceRestoreSpawnDelayCancelling {
    func cancel() {}
}

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
        let surface = makeSurface(
            runtimeSpawnPolicy: .pacedSessionRestore,
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )

        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func scheduledRestoreCreationCanRequeueWhenTheViewIsNotReady() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .pacedSessionRestore,
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )

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

        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func inputDemandForRestorePacedTerminalBypassesPendingRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .pacedSessionRestore,
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

    @Test func postShimScheduledRestoreReentersRestoreQueueBeforeNativeCreation() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .pacedSessionRestore,
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )

        surface.resumeSurfaceCreationAfterClaudeCommandShimReady(
            view: nativeView,
            source: .scheduledRestore
        )

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func queuedSocketInputPromotesBackgroundStartToInputDemand() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .pacedSessionRestore,
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

    @Test func inputDemandPromotesInFlightClaudeShimCreationSource() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .pacedSessionRestore,
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

    private func waitForSpawnCount(_ count: Int, spawned: () -> Int) async {
        for _ in 0..<100 {
            if spawned() >= count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) scheduled restored surface spawns")
    }

    private func makeSurface(
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        scheduler: RecordingRestoreSpawnScheduler,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost
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
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}

@MainActor
private final class RecordingRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    private(set) var scheduledSurfaceIds: [UUID] = []
    private var scheduledOperations: [@MainActor () -> Void] = []

    func scheduleRestoredSurfaceSpawn(surfaceId: UUID, operation: @escaping @MainActor () -> Void) {
        scheduledSurfaceIds.append(surfaceId)
        scheduledOperations.append(operation)
    }

    func runScheduledOperation(at index: Int = 0) {
        scheduledOperations[index]()
    }
}

private final class FakeSurfaceRegistry: TerminalSurfaceRegistering {
    func register(_ surface: any TerminalSurfacing) {}
    func unregister(_ surface: any TerminalSurfacing) {}
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {}
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {}
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? { nil }
    func surface(id: UUID) -> (any TerminalSurfacing)? { nil }
    func isRightSidebarDockSurface(id: UUID) -> Bool { false }
    func allSurfaces() -> [any TerminalSurfacing] { [] }
}

@MainActor
private final class FakeTerminalEngine: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { nil }
    var runtimeConfig: ghostty_config_t? { nil }
    var userGhosttyShellIntegrationMode: String { "none" }
}

@MainActor
private struct FakeTerminalSurfaceViewProvider: TerminalSurfaceViewProviding {
    let surfaceView: FakeTerminalSurfaceNativeView
    let paneHost: FakeTerminalSurfacePaneHost

    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        _ = initialFrame
        return (surfaceView, paneHost)
    }
}

private final class FakeTerminalSurfaceNativeView: NSView {
    var tabId: UUID?
    var hostedTabId: UUID? { tabId }
    weak var attachedController: (any TerminalSurfaceControlling)?
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { attachedController }
    var currentKeyStateIndicatorText: String? { nil }
    var isKeyboardCopyModeActive: Bool { false }

    func toggleKeyboardCopyMode() -> Bool { false }
    func applyWindowBackgroundIfActive() {}
    func forceRefreshSurface() -> Bool { true }
}

extension FakeTerminalSurfaceNativeView: @MainActor TerminalSurfaceHosting {}
extension FakeTerminalSurfaceNativeView: @MainActor TerminalSurfaceNativeViewing {}

@MainActor
private final class FakeTerminalSurfacePaneHost: NSView, TerminalSurfacePaneHosting {
    private let surfaceView: FakeTerminalSurfaceNativeView

    init(surfaceView: FakeTerminalSurfaceNativeView) {
        self.surfaceView = surfaceView
        super.init(frame: surfaceView.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable in tests")
    }

    func attachSurface(_ surface: TerminalSurface) {
        surfaceView.attachedController = surface
    }

    func cancelFocusRequest() {}
    func setVisibleInUI(_ visible: Bool) {}
    func setActive(_ active: Bool) {}
    func syncKeyStateIndicator(text: String?) {}
    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {}
}

@MainActor
private final class FakeSpawnPolicyProvider: TerminalSurfaceSpawnPolicyProviding {
    func currentSpawnPolicy() -> TerminalSurfaceSpawnPolicy {
        TerminalSurfaceSpawnPolicy(
            claudeHooksEnabled: true,
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
    }

    func controlSocketPath() -> String {
        "/tmp/cmux-test.sock"
    }
}

private final class FakeTerminalByteTee: TerminalByteTeeBinding {
    @MainActor
    func installTee(on surface: ghostty_surface_t, surfaceID: UUID) -> any TerminalByteTeeLease {
        FakeTerminalByteTeeLease()
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {}
}

private final class FakeTerminalByteTeeLease: TerminalByteTeeLease {
    func release() {}
}

private final class FakeRendererRealizationScheduler: TerminalRendererRealizationScheduling {
    @MainActor
    func scheduleImmediatePass() {}
}

private final class FakeHibernationRecorder: AgentHibernationRecording {
    func recordTerminalInput(workspaceId: UUID, panelId: UUID) {}
}
