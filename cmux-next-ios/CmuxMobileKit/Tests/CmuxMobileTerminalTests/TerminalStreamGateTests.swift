#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-14: "surely we don't need to stream the f***ing thing". A
/// terminal page streams the Mac's output only while someone can see it:
/// off screen 3 s, or in the background 45 s, and its session stops (the
/// decision is Rust's `terminal_stream_plan`; its table test is in
/// cmux-mobile-link-ffi `terminal_stream.rs`).
@MainActor @Suite struct TerminalStreamGateTests {
    @Test func aPageOffScreenStopsStreamingAfterThreeSeconds() async {
        let clock = SteppedClock()
        var told: [Bool] = []
        let gate = TerminalStreamGate(clock: clock) { told.append($0) }
        gate.set(pageShown: true)
        gate.set(pageShown: false)
        await clock.advance(by: .milliseconds(2_999))
        #expect(told.isEmpty, "a page stopped inside its grace: a quick tab flip would reattach")
        await clock.advance(by: .milliseconds(1))
        #expect(told == [false])
        #expect(!gate.streaming)
        // Shown again: at once.
        gate.set(pageShown: true)
        #expect(told == [false, true])
    }

    @Test func aQuickTabFlipKeepsTheStream() async {
        let clock = SteppedClock()
        var told: [Bool] = []
        let gate = TerminalStreamGate(clock: clock) { told.append($0) }
        gate.set(pageShown: true)
        for _ in 0..<5 {
            gate.set(pageShown: false)
            await clock.advance(by: .milliseconds(1_500))
            gate.set(pageShown: true)
        }
        await clock.advance(by: .seconds(60))
        #expect(told.isEmpty)
    }

    /// The background keeps the stream 45 s (the size claim goes at once).
    @Test func theBackgroundKeepsAShownPageStreamingFor45Seconds() async {
        let clock = SteppedClock()
        var told: [Bool] = []
        let gate = TerminalStreamGate(clock: clock) { told.append($0) }
        gate.set(pageShown: true)
        gate.set(appActive: false)
        await clock.advance(by: .seconds(44))
        #expect(told.isEmpty)
        await clock.advance(by: .seconds(1))
        #expect(told == [false])
        gate.set(appActive: true)
        #expect(told == [false, true])
    }

    @Test func aPageThatAppearsOffScreenStopsAfterTheGrace() async {
        let clock = SteppedClock()
        var told: [Bool] = []
        let gate = TerminalStreamGate(clock: clock) { told.append($0) }
        gate.set(pageShown: false)
        await clock.advance(by: .seconds(3))
        #expect(told == [false])
    }

    /// No page drives the gate (the full-screen terminal, the flood bench,
    /// a screen in a test window): it streams as before, background included.
    @Test func aScreenWithNoPageKeepsStreaming() async {
        let clock = SteppedClock()
        var told: [Bool] = []
        let gate = TerminalStreamGate(clock: clock) { told.append($0) }
        gate.set(appActive: false)
        await clock.advance(by: .seconds(600))
        #expect(told.isEmpty)
        #expect(gate.streaming)
    }
}

/// A clock that moves only when the test moves it; sleepers due by then wake.
private final class SteppedClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(due: Instant, wake: CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            let late = lock.withLock { () -> Bool in
                guard current < deadline else { return true }
                sleepers.append((deadline, wake))
                return false
            }
            if late { wake.resume() }
        }
    }

    /// Moves the time on and lets the woken sleepers run.
    @MainActor
    func advance(by duration: Duration) async {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current = current.advanced(by: duration)
            let now = current
            let due = sleepers.filter { !(now < $0.due) }.map(\.wake)
            sleepers.removeAll { !(now < $0.due) }
            return due
        }
        for wake in due { wake.resume() }
        for _ in 0..<20 { await Task.yield() }
    }
}
#endif
