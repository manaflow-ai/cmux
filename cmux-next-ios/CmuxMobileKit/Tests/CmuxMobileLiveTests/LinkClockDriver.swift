import Testing
@testable import CmuxMobileLive

/// Moves a `LinkController`'s time on a ``LinkTestClock`` one step at a time, and after each step
/// waits until everything that step set off has happened: the heartbeat that woke slept again
/// (its sleep is on the clock), a probe that started has its bound on the clock, an answering
/// probe's result was handled, and a probe whose bound passed was handled as timed out.
///
/// Time moves only in ``advance(by:)``, never while the controller still owes work for the
/// instant before. So what a test sees is the same whether its tasks run at once or the runner
/// is loaded and another test holds the main actor: a slow runner only makes the waits longer.
/// The waits have a watchdog (``pollUntil(within:sourceLocation:_:)``) that ends a test that would hang; it
/// never decides an outcome.
@MainActor
final class LinkClockDriver {
    let clock: LinkTestClock
    let controller: LinkController
    /// Whether the link answers a probe that started at the given instant; a silent link's
    /// probe ends only at its bound.
    private let probeAnswers: (LinkTestClock.Instant) -> Bool
    private var heartbeatSleeps = 0
    private var heartbeatDue: LinkTestClock.Instant?
    private var probeStarts = 0
    private var probeStart: LinkTestClock.Instant?
    private var probeBound: LinkTestClock.Instant?
    /// Sleeps the controller started and the clock has not seen yet.
    private var expected: [LinkTestClock.Instant] = []
    private var seenCalls = 0

    init(clock: LinkTestClock, controller: LinkController, probeAnswers: @escaping (LinkTestClock.Instant) -> Bool = { _ in true }) {
        self.clock = clock
        self.controller = controller
        self.probeAnswers = probeAnswers
    }

    /// Waits until the controller caught up with the clock (or `stop` holds).
    func settle(until stop: () -> Bool = { false }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await pollUntil(sourceLocation: sourceLocation) { stop() || caughtUp() }
    }

    /// Moves the clock by `step` and settles.
    func advance(by step: Duration, until stop: () -> Bool = { false },
                 sourceLocation: SourceLocation = #_sourceLocation) async throws {
        clock.advance(by: step)
        try await settle(until: stop, sourceLocation: sourceLocation)
    }

    /// Moves the clock to `end` in `step`s, settling after each, until `stop` holds.
    func run(until end: LinkTestClock.Instant, step: Duration = .milliseconds(100), stop: () -> Bool = { false },
             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await settle(until: stop, sourceLocation: sourceLocation)
        while clock.now < end, !stop() {
            try await advance(by: min(step, clock.now.duration(to: end)), until: stop, sourceLocation: sourceLocation)
        }
    }

    private func caughtUp() -> Bool {
        let now = clock.now
        // A heartbeat task that was started (link up, a background or foreground) and has not run
        // yet: its first sleep is still to come.
        guard controller.heartbeatsBegun == controller.heartbeatStarts else { return false }
        // A new heartbeat sleep (link up, a beat that re-armed, a restart) is due at now + its wait.
        let sleeps = controller.heartbeatSleeps
        if sleeps != heartbeatSleeps {
            #expect(sleeps == heartbeatSleeps + 1, "the heartbeat slept \(sleeps - heartbeatSleeps) times in one instant")
            heartbeatSleeps = sleeps
            let due = now.advanced(by: controller.lastHeartbeatWait)
            heartbeatDue = due
            expected.append(due)
        }
        // A new probe: its bound (timeout plus grace) goes on the clock now.
        let starts = controller.probeStarts
        if starts != probeStarts {
            #expect(starts == probeStarts + 1, "\(starts - probeStarts) probes started in one instant")
            probeStarts = starts
            probeStart = now
            let bound = now.advanced(by: controller.lastProbeTimeout + LinkController.probeGrace)
            probeBound = bound
            expected.append(bound)
        }
        let (calls, count) = clock.sleepCalls(from: seenCalls)
        seenCalls = count
        for call in calls {
            if let index = expected.firstIndex(of: call) { expected.remove(at: index) }
        }
        guard expected.isEmpty else { return false }
        // A dial in flight: its link's first probe and heartbeat start when it is adopted.
        if case .connecting = controller.phase { return false }
        // The retry timer is not followed here: a test that waits out a retry must not drift.
        if case .waiting = controller.phase {
            Issue.record("LinkClockDriver does not follow the retry timer (phase \(controller.phase))")
            return true
        }
        // The heartbeat woke and has not slept again yet (it ends instead once the link is down).
        if let due = heartbeatDue, due <= now, controller.phase.isConnected { return false }
        if controller.isProbing {
            if let bound = probeBound, bound <= now { return false }
            if let start = probeStart, probeAnswers(start) { return false }
        }
        return true
    }
}

/// Polls `condition` until it holds. The watchdog counts only time awake (``AwakeDeadline``) and
/// only ends a test that would otherwise hang.
@MainActor
func pollUntil(within watchdog: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: () -> Bool) async throws {
    var deadline = AwakeDeadline(watchdog)
    while !condition(), deadline.hasTimeLeft() {
        try await Task.sleep(for: .milliseconds(2)) // test: the poll interval of a watchdog, not a timing
    }
    try #require(condition(), "Timed out waiting for the controller", sourceLocation: sourceLocation)
}
