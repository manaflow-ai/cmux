#if DEBUG
import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CoreGraphics
import Testing

/// `debug.key {"sequence": ...}` (``DebugKeySequence``, ``DebugKeySequencePlayer``), which the burst
/// bench times every press by: events posted in order at their offsets, each stamped with its intended
/// press time (the start plus its offset, in the event system's ticks), a held key's repeats flagged,
/// and a new sequence cancelling the one playing so none of its events lands after.
@MainActor @Suite struct DebugKeySequenceTests {
    /// Cmd-D, then Cmd-Shift-D 40 ms later (a burst's first two presses), then a held W's repeat.
    private let steps: [JSONValue] = [
        ["key_code": 55, "down": true],
        ["key_code": 2, "down": true, "after_ms": 10],
        ["key_code": 2, "down": false, "after_ms": 8],
        ["key_code": 56, "down": true, "after_ms": 31],
        ["key_code": 2, "down": true, "after_ms": 1],
        ["key_code": 13, "down": true, "after_ms": 30, "repeat": true],
        ["key_code": 56, "down": false, "after_ms": 1],
        ["key_code": 55, "down": false, "after_ms": 2],
    ]
    private let stamp = DebugKeySequence.Stamp(base: 1_000, ticksPerSecond: 2e9)

    @Test func planKeepsOrderOffsetsModifiersAndRepeats() throws {
        let sequence = try #require(DebugKeySequence(steps))
        #expect(sequence.steps.map(\.offset) == [0, 10, 18, 49, 50, 80, 81, 83].map { Duration.milliseconds($0) })
        #expect(sequence.steps.map(\.isModifier) == [true, false, false, true, false, false, true, true])
        #expect(sequence.steps[4].flags == [.maskCommand, .maskShift], "Cmd-Shift-D carries both held modifiers")
        #expect(sequence.steps[7].flags == [], "the last key-up releases everything")
        #expect(sequence.steps.map(\.isRepeat) == [false, false, false, false, false, true, false, false])
        #expect(abs(sequence.durationSeconds - 0.083) < 1e-9)
        #expect(DebugKeySequence([["key_code": 2]]) == nil, "a step without down is refused")
        #expect(DebugKeySequence([["key_code": -1, "down": true]]) == nil, "a key code that is no virtual key code is refused")
        #expect(DebugKeySequence([["key_code": 2, "down": true, "after_ms": -5]]) == nil, "a negative gap is refused")
    }

    @Test func eachEventCarriesItsIntendedPressTime() throws {
        let sequence = try #require(DebugKeySequence(steps))
        let events = sequence.steps.compactMap { sequence.event($0, stamp: stamp, source: nil) }
        #expect(events.count == sequence.steps.count)
        // 2e9 ticks per second: 1 ms is 2,000,000 ticks after the base.
        let milliseconds: [CGEventTimestamp] = [0, 10, 18, 49, 50, 80, 81, 83]
        #expect(events.map(\.timestamp) == milliseconds.map { 1_000 + $0 * 2_000_000 })
        #expect(events[0].type == .flagsChanged && events[1].type == .keyDown && events[2].type == .keyUp)
        #expect(events[5].getIntegerValueField(.keyboardEventAutorepeat) == 1)
        #expect(events[4].getIntegerValueField(.keyboardEventAutorepeat) == 0)
        #expect(events[4].flags.contains(.maskShift) && events[4].flags.contains(.maskCommand))
    }

    @Test(.timeLimit(.minutes(1)))
    func playerPostsEveryStepInOrderAtItsOffset() async throws {
        let sequence = try #require(DebugKeySequence(steps))
        let deadlines = DeadlineLog()
        let posted = Posted()
        let player = DebugKeySequencePlayer()
        let task = player.play(sequence, stamp: stamp, source: nil, clock: TestClock(fires: true, deadlines: deadlines)) { posted.events.append($0) }
        #expect(player.isPlaying)
        await task.value
        #expect(!player.isPlaying)
        #expect(deadlines.all == sequence.steps.map(\.offset), "each step sleeps until its own offset from the start")
        #expect(posted.events.map { Optional($0.timestamp) } == sequence.steps.map { stamp.timestamp(at: $0.offset) })
        #expect(posted.events.map { CGKeyCode($0.getIntegerValueField(.keyboardEventKeycode)) } == sequence.steps.map(\.keyCode))
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewSequenceCancelsTheOnePlaying() async throws {
        let first = try #require(DebugKeySequence(steps))
        let second = try #require(DebugKeySequence([["key_code": 13, "down": true], ["key_code": 13, "down": false, "after_ms": 8]]))
        let posted = Posted()
        let post: @MainActor (CGEvent) -> Void = { posted.events.append($0) }
        let player = DebugKeySequencePlayer()
        let stalled = player.play(first, stamp: stamp, source: nil, clock: TestClock(fires: false, deadlines: nil), post: post)
        let playing = player.play(second, stamp: stamp, source: nil, clock: TestClock(fires: true, deadlines: nil), post: post)
        await stalled.value
        await playing.value
        #expect(posted.events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [13, 13], "only the new sequence's events land")
        #expect(!player.isPlaying)
    }
}

/// The events a player posted, in order.
@MainActor private final class Posted {
    var events: [CGEvent] = []
}

/// The deadlines a ``TestClock`` was asked to sleep until, as offsets from its start.
nonisolated private final class DeadlineLog: Sendable {
    // A lock: the clock's sleep is called from the player's task.
    private let deadlines = Mutex<[Duration]>([])

    func append(_ deadline: Duration) { deadlines.withLock { $0.append(deadline) } }
    var all: [Duration] { deadlines.withLock { $0 } }
}

/// A clock whose `now` is always its start: `fires` ends each sleep on the next task turn, else a
/// sleep ends only when its task is cancelled.
nonisolated private struct TestClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let fires: Bool
    let deadlines: DeadlineLog?

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        deadlines?.append(deadline.offset)
        if fires {
            await Task.yield()
        } else {
            // A stream nobody yields to: iterating it ends only when the task is cancelled. The
            // continuation is held to the end, since dropping it would finish the stream.
            let (pending, continuation) = AsyncStream<Void>.makeStream()
            for await _ in pending {}
            withExtendedLifetime(continuation) {}
        }
        try Task.checkCancellation()
    }
}
#endif
