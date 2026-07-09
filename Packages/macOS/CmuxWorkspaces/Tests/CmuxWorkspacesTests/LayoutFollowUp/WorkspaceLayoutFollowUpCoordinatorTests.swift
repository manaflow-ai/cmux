import Foundation
import Testing
@testable import CmuxWorkspaces

/// A virtual-time clock whose `sleep(for:)` suspends until the test
/// ``advance(by:)``s past the deadline; waiters fire in deadline order so the
/// zero-delay first attempt, the exponential-backoff retries, and the 2 s
/// timeout are distinguishable. Cancellation abandons the waiter, matching
/// `ContinuousClock`. Mirrors the `SessionAutosaveSchedulerTests` clock.
private final class ManualReleaseClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    // Justification: a test-only virtual clock. State guarded by `lock`;
    // `@unchecked Sendable` is required because `Clock.now`/`sleep` are
    // nonisolated and the state is mutated from both sleeping tasks and the
    // test driver.
    private let lock = NSLock()
    private var virtualNow: Duration = .zero
    private var waiters: [(deadline: Duration, resume: () -> Void)] = []

    var minimumResolution: Duration { .zero }

    var now: Instant {
        lock.lock(); defer { lock.unlock() }
        return Instant(offset: virtualNow)
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline.offset <= virtualNow {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((deadline.offset, { continuation.resume() }))
                    lock.unlock()
                }
            }
        } onCancel: {
            // The waiter never resumes, matching a cancelled real sleep.
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        virtualNow += duration
        var fired: [() -> Void] = []
        while let index = waiters.firstIndex(where: { $0.deadline <= virtualNow }) {
            fired.append(waiters.remove(at: index).resume)
        }
        lock.unlock()
        fired.forEach { $0() }
    }
}

/// In-memory host. The reconcile primitives are scripted: `terminalPortalPending`
/// /`browserVisibilityPending` flip to false once the test marks the layout
/// converged, so the coordinator's convergence loop terminates exactly as it
/// would against live portals.
@MainActor
private final class FakeFollowUpHost: WorkspaceLayoutFollowUpHosting {
    var terminalPortalPending = false
    var browserVisibilityPending = false
    var geometryNeedsAnotherPass = false

    private(set) var flushCount = 0
    private(set) var reconcileTerminalPortalCount = 0
    private(set) var reconcileBrowserReasons: [String] = []
    private(set) var hideAllCount = 0
    private(set) var movedReattachPanels: [UUID] = []
    private(set) var movedRefreshPanels: [UUID] = []

    private var onEvent: (@MainActor () -> Void)?

    func fireEvent() { onEvent?() }

    func beginObservingLayoutFollowUpEvents(
        onEvent: @escaping @MainActor () -> Void
    ) -> WorkspaceLayoutFollowUpObservation {
        self.onEvent = onEvent
        return WorkspaceLayoutFollowUpObservation { [weak self] in self?.onEvent = nil }
    }

    func layoutFollowUpFlushWindowLayouts() { flushCount += 1 }
    func layoutFollowUpReconcileTerminalGeometryPass() -> Bool { geometryNeedsAnotherPass }
    func layoutFollowUpReconcileTerminalPortalVisibility() { reconcileTerminalPortalCount += 1 }
    func layoutFollowUpTerminalPortalVisibilityNeedsFollowUp() -> Bool { terminalPortalPending }
    func layoutFollowUpReconcileBrowserPortalVisibility(reason: String) { reconcileBrowserReasons.append(reason) }
    func layoutFollowUpBrowserPortalVisibilityNeedsFollowUp() -> Bool { browserVisibilityPending }
    func layoutFollowUpEnsureTerminalFocus(panelId: UUID) -> Bool { true }
    func layoutFollowUpTerminalFocusNeedsFollowUp(panelId: UUID) -> Bool { false }
    func layoutFollowUpReconcilePendingBrowserPanel(panelId: UUID, reason: String) -> Bool { true }
    func layoutFollowUpBrowserPanelNeedsFollowUp(panelId: UUID) -> Bool { false }
    func layoutFollowUpReconcileBrowserExitFocus(panelId: UUID) -> Bool { false }
    func layoutFollowUpRequestMovedTerminalReattach(panelId: UUID) { movedReattachPanels.append(panelId) }
    func layoutFollowUpRefreshMovedTerminal(panelId: UUID) { movedRefreshPanels.append(panelId) }
    func layoutFollowUpIsTerminalPanel(panelId: UUID) -> Bool { true }
    func layoutFollowUpHideAllPortals() { hideAllCount += 1 }
}

/// A reparent-suppression view recording its suppress/clear calls; the
/// `canClear…` answer is scriptable so a test drives the ready-clear path.
@MainActor
private final class FakeSuppressibleView: WorkspaceReparentSuppressible {
    private(set) var suppressed = false
    private(set) var clearedCount = 0
    var canClear = false

    func suppressReparentFocus() { suppressed = true }
    func clearSuppressReparentFocus() { clearedCount += 1; suppressed = false }
    func canClearPendingReparentFocusSuppressionAfterLayoutAttempt() -> Bool { canClear }
}

@MainActor
@Suite struct WorkspaceLayoutFollowUpCoordinatorTests {
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func make(
        host: FakeFollowUpHost,
        clock: ManualReleaseClock
    ) -> WorkspaceLayoutFollowUpCoordinator {
        let coordinator = WorkspaceLayoutFollowUpCoordinator(clock: clock, timeout: .seconds(2))
        coordinator.attach(host: host)
        return coordinator
    }

    @Test func convergedBeginRunsOneAttemptAndClears() async {
        let host = FakeFollowUpHost()
        let clock = ManualReleaseClock()
        let coordinator = make(host: host, clock: clock)

        coordinator.begin(reason: "test.split", includeGeometry: true)
        await settle()
        // First attempt is deferred via a zero-delay sleep.
        clock.advance(by: .zero)
        await settle()

        #expect(host.flushCount == 1)
        #expect(host.reconcileTerminalPortalCount == 1)
        #expect(host.reconcileBrowserReasons == ["test.split"])
        // Nothing pending -> converged -> a further event does not re-arm
        // (observation cleared).
        host.fireEvent()
        await settle()
        clock.advance(by: .seconds(1))
        await settle()
        #expect(host.flushCount == 1)
    }

    @Test func stalledAttemptRetriesWithBackoffUntilConverged() async {
        let host = FakeFollowUpHost()
        host.terminalPortalPending = true
        let clock = ManualReleaseClock()
        let coordinator = make(host: host, clock: clock)

        coordinator.begin(reason: "test.retry")
        await settle()
        clock.advance(by: .zero) // first attempt: still pending, no progress -> stall=1
        await settle()
        #expect(host.flushCount == 1)

        // A subsequent event schedules the next attempt at the backoff delay
        // (0.01 s for stall=1). Advancing less than the delay does not fire it.
        host.fireEvent()
        await settle()
        clock.advance(by: .milliseconds(5))
        await settle()
        #expect(host.flushCount == 1)
        clock.advance(by: .milliseconds(5))
        await settle()
        #expect(host.flushCount == 2)

        // Now the layout converges; the next attempt clears the follow-up.
        host.terminalPortalPending = false
        host.fireEvent()
        await settle()
        clock.advance(by: .seconds(1))
        await settle()
        let convergedFlushCount = host.flushCount
        // Once cleared, further events do not re-arm.
        host.fireEvent()
        await settle()
        clock.advance(by: .seconds(1))
        await settle()
        #expect(host.flushCount == convergedFlushCount)
    }

    @Test func timeoutClearsAStalledFollowUp() async {
        let host = FakeFollowUpHost()
        host.terminalPortalPending = true
        let clock = ManualReleaseClock()
        let coordinator = make(host: host, clock: clock)

        coordinator.begin(reason: "test.timeout")
        await settle()
        clock.advance(by: .zero) // one stalled attempt
        await settle()
        #expect(host.flushCount == 1)

        // The 2 s watchdog fires and clears, so a later event does not re-arm.
        clock.advance(by: .seconds(2))
        await settle()
        host.terminalPortalPending = false
        host.fireEvent()
        await settle()
        clock.advance(by: .seconds(1))
        await settle()
        #expect(host.flushCount == 1)
    }

    @Test func suppressReparentFocusClearsOnReadyAttempt() async {
        let host = FakeFollowUpHost()
        let clock = ManualReleaseClock()
        let coordinator = make(host: host, clock: clock)
        let view = FakeSuppressibleView()

        coordinator.suppressReparentFocus(view, reason: "test.reparent")
        #expect(view.suppressed)
        #expect(coordinator.hasActivePendingReparentFocusSuppressions)
        #expect(coordinator.hasPendingReparentFocusSuppression(for: view))

        // Not ready yet: the attempt keeps the suppression and stays armed.
        view.canClear = false
        await settle()
        clock.advance(by: .zero)
        await settle()
        #expect(coordinator.hasActivePendingReparentFocusSuppressions)

        // Ready: the next attempt clears the suppression and converges.
        view.canClear = true
        host.fireEvent()
        await settle()
        clock.advance(by: .milliseconds(20))
        await settle()
        #expect(!coordinator.hasActivePendingReparentFocusSuppressions)
        #expect(view.clearedCount >= 1)
    }

    @Test func disablingPortalRenderingHidesAllAndClears() async {
        let host = FakeFollowUpHost()
        host.terminalPortalPending = true
        let clock = ManualReleaseClock()
        let coordinator = make(host: host, clock: clock)

        coordinator.begin(reason: "test.disable")
        await settle()
        clock.advance(by: .zero)
        await settle()

        coordinator.setPortalRenderingEnabled(false, reason: "test.disable")
        #expect(host.hideAllCount == 1)
        #expect(!coordinator.portalRenderingEnabled)
        // While disabled, begin() is inert.
        coordinator.begin(reason: "test.disabledBegin")
        await settle()
        let flushAfterDisable = host.flushCount
        clock.advance(by: .seconds(1))
        await settle()
        #expect(host.flushCount == flushAfterDisable)
    }

    @Test func movedTerminalRefreshRunsTwoDeferredPasses() async {
        let host = FakeFollowUpHost()
        let clock = ManualReleaseClock()
        let coordinator = make(host: host, clock: clock)
        let panelId = UUID()

        coordinator.scheduleMovedTerminalRefresh(panelId: panelId)
        // The reattach is synchronous, but BOTH refresh passes are deferred onto a
        // Clock-sleep `Task` (legacy `asyncAfter(0)` + `asyncAfter(0.03)`). Before
        // the current turn yields, neither pass has run — running the first pass
        // inline would re-enter AppKit layout inside the bonsplit delegate callback
        // that calls this. The reattach, by contrast, happens immediately.
        #expect(host.movedReattachPanels == [panelId])
        #expect(host.movedRefreshPanels == [])

        // First pass fires on the next turn (the .zero sleep resolves once the
        // current turn yields; the manual clock releases a zero deadline on await).
        await settle()
        #expect(host.movedRefreshPanels == [panelId])

        // Second pass fires 0.03 s later.
        clock.advance(by: .milliseconds(30))
        await settle()
        #expect(host.movedRefreshPanels == [panelId, panelId])
    }
}
