import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// The frame scheduler's stall timer (FrameScheduler.swift): it notices when the display link
/// stops while clients are active, and it costs no work per frame.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameStallTimerTests {
    /// The sweep (m27 background-stalls): every display frame cancelled the stall timer's task and
    /// made a new one, two cooperative-pool wakes per frame (240 a second at 120 Hz for each
    /// ticking window), seen on main as `workq_kernreturn` and `Task.init` under load. A second
    /// of frames arms the timer once.
    @Test func aSecondOfFramesArmsTheStallTimerOnce() {
        let media = MediaTime()
        let scheduler = FrameScheduler.testing(clock: StallClock(), mediaTime: media.read) { _ in StallFakeLink() }
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }
        spring.activate()
        for _ in 0..<120 {
            media.advance(seconds: 1.0 / 120)
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 120)
        }
        #expect(scheduler.stallTimerArms == 1, "armed \(scheduler.stallTimerArms) times for 120 frames")
        spring.deactivate()
    }

    /// Frames that stop are still seen as a stall about one timeout after the last frame, and the
    /// record starts at the last frame's timestamp, not at the time the timer noticed.
    @Test func framesThatStopAreAStallFromTheLastFrame() async throws {
        let media = MediaTime()
        let clock = StallClock()
        let scheduler = FrameScheduler.testing(clock: clock, mediaTime: media.read) { _ in StallFakeLink() }
        var ticks = 0
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in ticks += 1; return true }
        spring.activate()
        try await clock.waitForSleeper()
        // 50 ms of frames, then none.
        for _ in 0..<6 {
            media.advance(seconds: 1.0 / 120)
            clock.advance(by: .seconds(1.0 / 120))
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 120)
        }
        let lastFrame = media.now
        // The timer is asleep before time moves on (a timer task reads the clock when it starts).
        try await clock.waitForSleeper()
        media.advance(seconds: 0.06)
        clock.advance(by: .milliseconds(60))
        try await clock.waitForSleeper()
        #expect(scheduler.lastStall == nil, "60 ms after the last frame is not a stall yet")
        let ticksBefore = ticks
        media.advance(seconds: 0.045)
        clock.advance(by: .milliseconds(45))
        try await clock.waitForSleeper()
        let stall = try #require(scheduler.lastStall, "105 ms after the last frame is a stall")
        #expect(stall.startedAt == lastFrame)
        #expect(stall.detectedAt == media.now)
        #expect(ticks == ticksBefore + 1, "the clients ticked without the link")
        spring.deactivate()
    }
}

/// `CACurrentMediaTime` for tests.
@MainActor
private final class MediaTime {
    private(set) var now: CFTimeInterval = 1000
    // Strong, as MainFrameBudgetTests' BudgetClock: a stall timer can read it after its test returned.
    var read: @MainActor () -> CFTimeInterval { { [self] in self.now } }
    func advance(seconds: Double) { now += seconds }
}

@MainActor
private final class StallFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// A clock that moves only when the test advances it.
private final class StallClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var cancelled: Set<Int> = []
        var nextID = 0
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    nonisolated deinit {}

    @concurrent func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits (bounded) until a timer is asleep on the clock: the stall timer reads `now` for its
    /// deadline when its task starts, so the test advances only after that.
    func waitForSleeper() async throws {
        for _ in 0..<20 where state.withLock({ $0.sleepers.isEmpty }) { await Task.yield() }
        for _ in 0..<500 where state.withLock({ $0.sleepers.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        if state.withLock({ $0.sleepers.isEmpty }) { throw NoSleeper() }
    }

    struct NoSleeper: Error, CustomStringConvertible {
        var description: String { "no timer went to sleep on the clock within 2.5 s" }
    }

    /// Moves the clock on and wakes every sleeper whose deadline it reached.
    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
