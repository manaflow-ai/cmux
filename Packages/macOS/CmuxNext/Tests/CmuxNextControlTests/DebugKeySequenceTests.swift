#if DEBUG
import AppKit
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

    /// A probe with no timestamp gives no unit (macOS 27, 2026-10-31: a fresh probe event carries timestamp 0, so every
    /// sequence was refused; the start then came from the host's mach ticks at the timebase's rate). Decision of
    /// 2026-11-17: the start comes from the host's clock in the unit that AppKit reads from a probe that the app
    /// stamped. On a Mac with macOS 26.7 AppKit read the mach ticks as nanoseconds, so each event of a sequence was
    /// older than it was by 122/125 of the time since boot.
    @Test func startWithNoProbeTimestampIsTheHostsTimeInTheUnitThatAppKitReads() throws {
        // A probe with a timestamp: its own ticks and rate, as before; the stamped rate is not asked.
        let probed = try #require(DebugKeySequence.Stamp.start(probeTimestamp: 4_000_000_000, probeSeconds: 2.0, hostTicks: 99,
                                                              timebaseNumer: 125, timebaseDenom: 3) { _ in 7 })
        #expect(probed == DebugKeySequence.Stamp(base: 4_000_000_000, ticksPerSecond: 2e9))
        // No timestamp. 48,000,000 mach ticks at 125/3 ns per tick (24 MHz, Apple silicon) are 2 s since boot.
        let probe = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        // AppKit reads an event's ticks as nanoseconds: the start is 2 s in nanoseconds.
        let asNanoseconds = try #require(DebugKeySequence.Stamp.start(probeTimestamp: 0, probeSeconds: 0, hostTicks: 48_000_000,
                                                                     timebaseNumer: 125, timebaseDenom: 3) { ticks in
            DebugKeySequence.Stamp.eventTicksPerSecond(stamping: probe, with: ticks) { Double($0.timestamp) / 1e9 }
        })
        #expect(asNanoseconds.base == 2_000_000_000)
        #expect(asNanoseconds.ticksPerSecond == 1e9)
        #expect(asNanoseconds.timestamp(at: .milliseconds(800)) == 2_800_000_000, "an 800 ms hold lands 0.8 s later")
        // AppKit reads an event's ticks as the host's mach ticks: the start is 2 s in those ticks.
        let asMachTicks = try #require(DebugKeySequence.Stamp.start(probeTimestamp: 0, probeSeconds: 0, hostTicks: 48_000_000,
                                                                   timebaseNumer: 125, timebaseDenom: 3) { ticks in
            DebugKeySequence.Stamp.eventTicksPerSecond(stamping: probe, with: ticks) { Double($0.timestamp) / 24_000_000 }
        })
        #expect(asMachTicks.base == 48_000_000)
        #expect(abs(asMachTicks.ticksPerSecond - 24_000_000) < 1e-3)
        #expect(asMachTicks.timestamp(at: .milliseconds(800)) == 48_000_000 + 19_200_000, "an 800 ms hold lands 0.8 s later")
        // No usable clock at all: still refused.
        #expect(DebugKeySequence.Stamp.start(probeTimestamp: 0, probeSeconds: nil, hostTicks: 0,
                                            timebaseNumer: 1, timebaseDenom: 1) { _ in 1e9 } == nil)
        #expect(DebugKeySequence.Stamp.start(probeTimestamp: 0, probeSeconds: 0, hostTicks: 10,
                                            timebaseNumer: 0, timebaseDenom: 1) { _ in 1e9 } == nil)
    }

    /// A read with no usable seconds (none, zero, below zero, not finite) gives nanoseconds, the documented unit of an
    /// event's timestamp.
    @Test func aStampedProbeWithNoUsableSecondsIsReadInNanoseconds() throws {
        let probe = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let unusable: [Double?] = [nil, 0, -2, .infinity, -.infinity, .nan]
        for seconds in unusable {
            let rate = DebugKeySequence.Stamp.eventTicksPerSecond(stamping: probe, with: 2_000_000_000) { _ in seconds }
            #expect(rate == 1e9, "a read of \(String(describing: seconds)) s gave \(rate) ticks in a second, want 1e9")
        }
        #expect(probe.timestamp == 2_000_000_000, "the probe does not carry the ticks that the read is of")
        let start = DebugKeySequence.Stamp.start(probeTimestamp: 0, probeSeconds: nil, hostTicks: 48_000_000,
                                                 timebaseNumer: 125, timebaseDenom: 3) { ticks in
            DebugKeySequence.Stamp.eventTicksPerSecond(stamping: probe, with: ticks) { _ in nil }
        }
        #expect(start == DebugKeySequence.Stamp(base: 2_000_000_000, ticksPerSecond: 1e9))
    }

    /// The unit by a run on this Mac: a real probe event, stamped with the host's nanoseconds now and read by AppKit
    /// (`NSEvent(cgEvent:)`), as `debug.key` does for a probe with no timestamp. The rate must be nanoseconds or the
    /// host's mach rate, and AppKit must read the start of a sequence as the host's time since boot. The row prints
    /// what it read.
    @Test func appKitReadsAStampedProbeInNanosecondsOrInTheHostsMachTicks() throws {
        let probe = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 0, keyDown: true))
        let appKit: (CGEvent) -> Double? = { NSEvent(cgEvent: $0)?.timestamp }
        let fresh = (ticks: probe.timestamp, seconds: appKit(probe))
        try #require(fresh.seconds != nil, "AppKit made no event from the probe: this row needs a session of the window server")
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let machRate = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        let hostTicks = mach_absolute_time()
        let hostSeconds = Double(hostTicks) / machRate
        let rate = DebugKeySequence.Stamp.eventTicksPerSecond(stamping: probe, with: CGEventTimestamp((hostSeconds * 1e9).rounded()),
                                                              read: appKit)
        let stamped = (ticks: probe.timestamp, seconds: appKit(probe))
        let start = try #require(DebugKeySequence.Stamp.start(probeTimestamp: 0, probeSeconds: nil, hostTicks: hostTicks,
                                                             timebaseNumer: timebase.numer, timebaseDenom: timebase.denom) { ticks in
            DebugKeySequence.Stamp.eventTicksPerSecond(stamping: probe, with: ticks, read: appKit)
        })
        probe.timestamp = start.base
        let startSeconds = appKit(probe)
        print("debug key sequence stamp on this Mac: a fresh probe has timestamp \(fresh.ticks) and AppKit reads "
            + "\(String(describing: fresh.seconds)) s from it; a probe stamped with \(stamped.ticks) (the host's nanoseconds "
            + "since boot) reads as \(String(describing: stamped.seconds)) s: \(rate) event ticks in a second; the host's "
            + "mach clock has \(machRate) ticks in a second (timebase \(timebase.numer)/\(timebase.denom)); the start of a "
            + "sequence has base \(start.base) at \(start.ticksPerSecond) ticks in a second, and AppKit reads it as "
            + "\(String(describing: startSeconds)) s; the host's time since boot was \(hostSeconds) s")
        #expect(rate.isFinite && rate > 0, "the rate is \(rate)")
        #expect(abs(rate / 1e9 - 1) < 1e-6 || abs(rate / machRate - 1) < 1e-6,
                "AppKit takes \(rate) event ticks for a second: not nanoseconds and not the host's mach rate (\(machRate))")
        let read = try #require(startSeconds, "AppKit made no event from the probe with the start's timestamp")
        #expect(abs(read - hostSeconds) < 1e-3,
                "AppKit reads the start of a sequence as \(read) s; the host's time since boot was \(hostSeconds) s")
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
