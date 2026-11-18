import CmuxNextCompat
import CmuxNextDesignTokens
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A slow mark is not for the whole run (Lawrence 2026-11-10: "cmd n is lowkey hella slow"). On a Mac
/// at load 250, making the New Tab spare took over a second of wall time once; the gate then stayed
/// `slow`, the pool never made another spare, and every Cmd-T and Cmd-N after it loaded a page cold.
/// The gate asks WebKit's setup again after ``WebKitSetupGate/recheck``, and a setup that answers
/// makes it ready (the pool warms again). A wedged sandboxd, whose probe never returns, still gets no
/// second probe thread and stays slow.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct WebKitSetupGateRecheckTests {
    @Test func aSlowMarkIsAskedAgainAndReadyOnceSetupAnswers() async throws {
        let clock = ManualClock()
        let gate = WebKitSetupGate(clock: clock)
        gate.request = {}
        var answered = 0
        try await probe(gate) { answered += 1 }
        #expect(gate.state == .ready)
        #expect(answered == 1)

        gate.markSlow() // one spare took over a second on a loaded Mac
        #expect(gate.state == .slow)
        try await clock.waitForSleeper()
        clock.advance(by: WebKitSetupGate.recheck)
        try await waitUntil { gate.state == .ready }
        #expect(answered == 2, "the pool was not told to warm again")
    }

    @Test func aWedgedProbeStartsNoSecondThread() async throws {
        let clock = ManualClock()
        let gate = WebKitSetupGate(clock: clock)
        let started = Counter()
        gate.request = { started.add(); Thread.sleep(forTimeInterval: 600) } // a wedged sandboxd
        gate.probe {}
        try await waitUntil { started.value == 1 }
        // The probe's own timeout, then the recheck: neither starts another thread while the first hangs.
        try await clock.waitForSleeper()
        clock.advance(by: WebKitSetupGate.timeout)
        try await waitUntil { gate.state == .slow }
        clock.advance(by: WebKitSetupGate.recheck * 4)
        gate.probe {}
        try await Task.sleep(for: .milliseconds(200)) // test harness: room for a wrongly started thread to run
        #expect(started.value == 1)
        #expect(gate.state == .slow)
    }

    private func probe(_ gate: WebKitSetupGate, answered: @escaping @MainActor () -> Void) async throws {
        gate.probe(answered: answered)
        try await waitUntil { gate.state == .ready }
    }

    /// Turns the main actor until `condition` holds (the probe answers from its own thread).
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            #expect(ContinuousClock.now < deadline, "timed out")
            if ContinuousClock.now >= deadline { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5)) // test harness: the probe thread hops to the main actor
        }
    }
}

/// A count bumped from the probe's own thread (lock carve-out: one integer, synchronous callers).
nonisolated private final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func add() { count.withLock { $0 += 1 } }
}
