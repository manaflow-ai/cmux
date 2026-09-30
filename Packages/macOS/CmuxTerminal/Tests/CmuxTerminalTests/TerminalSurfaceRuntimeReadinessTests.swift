import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite
struct TerminalSurfaceRuntimeReadinessTests {
    @Test("Closing settles a readiness waiter without spending the caller budget")
    func closeSettlesWaiterImmediately() async {
        let clock = ManualReadinessBudgetClock()
        let surface = makeHeldSurface(clock: clock)
        var budgetStarts = clock.startedSleeps.makeAsyncIterator()

        let wait = Task { await surface.waitForRuntimeSurfaceReady() }
        // The budget only runs once the waiter has registered and suspended.
        _ = await budgetStarts.next()
        #expect(surface.runtimeReadinessWaiters.count == 1)

        surface.beginPortalCloseLifecycle(reason: "readiness-test")

        #expect(await wait.value == false)
        #expect(surface.runtimeReadinessWaiters.isEmpty)
    }

    @Test("Agent hibernation settles a readiness waiter without spending the caller budget")
    func hibernationSettlesWaiterImmediately() async {
        let clock = ManualReadinessBudgetClock()
        let surface = makeHeldSurface(clock: clock)
        var budgetStarts = clock.startedSleeps.makeAsyncIterator()

        let wait = Task { await surface.waitForRuntimeSurfaceReady() }
        _ = await budgetStarts.next()
        #expect(surface.runtimeReadinessWaiters.count == 1)

        #expect(surface.suspendRuntimeSurfaceForAgentHibernation(reason: "readiness-test"))

        #expect(await wait.value == false)
        #expect(surface.runtimeReadinessWaiters.isEmpty)
    }

    @Test("The caller budget bounds a wait the lifecycle never answers")
    func budgetBoundsAnUnansweredWait() async {
        let clock = ManualReadinessBudgetClock()
        let surface = makeHeldSurface(clock: clock)
        var budgetStarts = clock.startedSleeps.makeAsyncIterator()

        let wait = Task { await surface.waitForRuntimeSurfaceReady() }
        _ = await budgetStarts.next()
        #expect(surface.runtimeReadinessWaiters.count == 1)

        clock.expire()

        #expect(await wait.value == false)
        #expect(surface.runtimeReadinessWaiters.isEmpty)
    }

    @Test("Cancelling the caller settles and removes its waiter")
    func cancellationSettlesWaiter() async {
        let clock = ManualReadinessBudgetClock()
        let surface = makeHeldSurface(clock: clock)
        var budgetStarts = clock.startedSleeps.makeAsyncIterator()

        let wait = Task { await surface.waitForRuntimeSurfaceReady() }
        _ = await budgetStarts.next()
        #expect(surface.runtimeReadinessWaiters.count == 1)

        wait.cancel()

        #expect(await wait.value == false)
        #expect(surface.runtimeReadinessWaiters.isEmpty)
    }

    @Test("A native creation failure is recorded separately from a still-starting runtime")
    func failedNativeCreationIsNotReportedAsStillStarting() async {
        let surface = makeSurface(
            clock: ManualReadinessBudgetClock(),
            runtimeSpawnPolicy: .immediate
        )

        #expect(await surface.waitForRuntimeSurfaceReady() == false)
        #expect(surface.runtimeSurfaceCreationFailed)
    }

    @Test("A closed surface answers without registering a waiter")
    func closedSurfaceAnswersImmediately() async {
        let surface = makeHeldSurface(clock: ManualReadinessBudgetClock())
        surface.beginPortalCloseLifecycle(reason: "readiness-test")

        #expect(await surface.waitForRuntimeSurfaceReady() == false)
        #expect(surface.runtimeReadinessWaiters.isEmpty)
    }

    /// A surface held for restore admission: a readiness request cannot start
    /// its runtime, so only the lifecycle or the caller budget can answer.
    private func makeHeldSurface(clock: ManualReadinessBudgetClock) -> TerminalSurface {
        makeSurface(clock: clock, runtimeSpawnPolicy: .heldForStartupRestoreAdmission)
    }

    private func makeSurface(
        clock: ManualReadinessBudgetClock,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: FakeTerminalSurfacePaneHost(
                        surfaceView: nativeView,
                        attachesThroughSurfaceModel: true
                    )
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: RecordingRestoreSpawnScheduler(),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    agentCommandShimRootDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                runtimeReadinessClock: clock,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}

/// A virtual clock for one readiness budget. Each sleep reports that it began
/// and elapses only when the test expires it; cancellation ends it early.
struct ManualReadinessBudgetClock: Clock {
    typealias Instant = ContinuousClock.Instant

    let startedSleeps: AsyncStream<Void>
    private let startedSleepsContinuation: AsyncStream<Void>.Continuation
    private let expirations: AsyncStream<Void>
    private let expirationsContinuation: AsyncStream<Void>.Continuation

    init() {
        (startedSleeps, startedSleepsContinuation) = AsyncStream.makeStream()
        (expirations, expirationsContinuation) = AsyncStream.makeStream()
    }

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        startedSleepsContinuation.yield()
        for await _ in expirations { return }
        throw CancellationError()
    }

    /// Elapses the pending sleep, as if the caller budget ran out.
    func expire() {
        expirationsContinuation.yield()
    }
}
