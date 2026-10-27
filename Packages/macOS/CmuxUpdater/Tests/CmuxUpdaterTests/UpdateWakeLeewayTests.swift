import Foundation
import Testing
@testable import CmuxUpdater

/// Updater deadlines sleep with a leeway, and a held relaunch rechecks on a backoff instead of a
/// fixed 2 s period, so an idle Mac with an update waiting is not woken on a short period
/// (plans/cmux-next/chrome-parity/p14-energy.md, Q2).
@MainActor
@Suite struct UpdateWakeLeewayTests {
    @Test(arguments: [
        (Duration.seconds(-1), Duration.zero),
        (.zero, .zero),
        (.milliseconds(20), .zero),
        (.milliseconds(36), .milliseconds(8)),
        (.milliseconds(250), .milliseconds(25)),
        (.seconds(2), .milliseconds(200)),
        (.seconds(20), .seconds(1)),
        (.seconds(15 * 60), .seconds(1)),
    ])
    nonisolated func leewayIsTenPercentBetweenEightMillisecondsAndOneSecond(delay: Duration, leeway: Duration) {
        #expect(delay.updateWakeLeeway == leeway)
    }

    /// Pumps the cooperative pool until the clock saw `request` (the sleep runs in a main-actor task).
    private func waitForRequest(_ request: RequestedSleep, on clock: TestDeadlineClock,
                                sourceLocation: SourceLocation = #_sourceLocation) async {
        var spins = 0
        while spins < 20_000, await !clock.requests.contains(request) {
            spins += 1
            await Task.yield()
        }
        let requests = await clock.requests
        #expect(requests.contains(request), "requests: \(requests)", sourceLocation: sourceLocation)
    }

    @Test func installWatchdogDeadlineAsksLeeway() async {
        let clock = TestDeadlineClock()
        let watchdog = InstallWatchdog(clock: clock, timeout: installWatchdogTimeout)

        watchdog.arm(onTimeout: {})

        await waitForRequest(RequestedSleep(duration: .seconds(25), tolerance: .seconds(1)), on: clock)
        watchdog.disarm()
    }

    @Test func checkTimeoutAsksLeeway() async {
        let clock = TestDeadlineClock()
        let driver = UpdateDriver(model: UpdateStateModel(), log: NoopUpdateLog(), clock: clock)

        driver.showUserInitiatedUpdateCheck(cancellation: {})

        await waitForRequest(RequestedSleep(duration: .seconds(10), tolerance: .seconds(1)), on: clock)
        driver.setState(.idle)
    }

    @Test func wakeCheckDelayAsksLeeway() async {
        let harness = Harness()

        harness.controller.systemDidWake()

        await waitForRequest(RequestedSleep(duration: .seconds(20), tolerance: .seconds(1)), on: harness.clock)
        harness.controller.wakeCheckTask?.cancel()
    }

    @Test func noUpdateDismissAsksLeeway() async {
        let harness = Harness()
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        for _ in 0..<20_000 where harness.updater.checkForUpdatesCallCount == 0 {
            await Task.yield()
        }

        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(.notFound(.init(acknowledgement: {})))

        await waitForRequest(RequestedSleep(duration: .seconds(5), tolerance: .milliseconds(500)), on: harness.clock)
    }

    /// Fires one parked recheck and waits, bounded, until the gate read the blockers again.
    private func recheck(_ clock: TestDeadlineClock, until condition: () -> Bool) async {
        await clock.fireDeadlineWhenReady(timeout: .seconds(20))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test func aHeldRelaunchBacksOffWhileItsBlockersStayTheSame() async {
        let clock = TestDeadlineClock()
        let gate = UpdateRelaunchGate(clock: clock, log: NoopUpdateLog())
        var evaluations = 0
        gate.hold(
            isAutoUpdate: false,
            blockers: {
                evaluations += 1
                // A running command holds a user install with no time bound.
                return UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1)
            },
            isShown: { true },
            publish: { _ in },
            relaunch: { Issue.record("relaunch must not run") },
            later: {}
        )
        for expected in 2...6 {
            await recheck(clock) { evaluations == expected }
        }

        let requests = await clock.requests
        #expect(Array(requests.prefix(5)) == [
            RequestedSleep(duration: .seconds(2), tolerance: .milliseconds(200)),
            RequestedSleep(duration: .seconds(4), tolerance: .milliseconds(400)),
            RequestedSleep(duration: .seconds(8), tolerance: .milliseconds(800)),
            RequestedSleep(duration: .seconds(16), tolerance: .seconds(1)),
            RequestedSleep(duration: .seconds(16), tolerance: .seconds(1)),
        ])
        gate.cancel()
    }

    @Test func aBlockerChangeRestartsTheRecheckAtItsShortestInterval() async {
        let clock = TestDeadlineClock()
        let gate = UpdateRelaunchGate(clock: clock, log: NoopUpdateLog())
        var blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1)
        var evaluations = 0
        gate.hold(
            isAutoUpdate: false,
            blockers: {
                evaluations += 1
                return blockers
            },
            isShown: { true },
            publish: { _ in },
            relaunch: { Issue.record("relaunch must not run") },
            later: {}
        )
        await recheck(clock) { evaluations == 2 }
        await recheck(clock) { evaluations == 3 }
        blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 2)
        await recheck(clock) { evaluations == 4 }
        await recheck(clock) { evaluations == 5 }

        let durations = await clock.requests.prefix(4).map(\.duration)
        #expect(durations == [.seconds(2), .seconds(4), .seconds(8), .seconds(2)])
        gate.cancel()
    }

    @Test func theBackoffNeverSleepsPastTheAgentTimeout() async {
        let clock = TestDeadlineClock()
        let gate = UpdateRelaunchGate(clock: clock, log: NoopUpdateLog(), agentTimeout: .seconds(5))
        var relaunched = 0
        gate.hold(
            isAutoUpdate: false,
            blockers: { UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0) },
            isShown: { true },
            publish: { _ in },
            relaunch: { relaunched += 1 },
            later: { Issue.record("later must not run") }
        )
        // 2 s, then 3 s (not 4 s): the hold ends exactly at the 5 s agent timeout.
        await recheck(clock) { true }
        await recheck(clock) { relaunched == 1 }

        let durations = await clock.requests.map(\.duration)
        #expect(durations == [.seconds(2), .seconds(3)])
        #expect(!gate.isWaiting)
    }
}
