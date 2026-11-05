#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Fleet bench, 2026-10-26 (scripts/ci/cmux-next-ios-sim.sh): with slow
/// output (`top`, 0.01 Mbit/s) and when idle, keystroke echo read 413 ms
/// with two echoes always pending, while floods read 14 ms; `drain` was -1
/// in every run. The screen parses the attach's mirror reset (`ESC c`, two
/// bytes) while the replay gate waits for the replay, and returned before
/// it told the bench probe, so the probe's byte count ran two bytes behind
/// the stream. A one-byte echo then counted as parsed only after two more
/// keystrokes (2 x 200 ms + the real ~13 ms), and the drain check
/// (`processed >= emitted + 2`) never held. Floods hid it: their bytes
/// covered the gap at once.
///
/// Through the real screen (`TerminalViewController`) and Ghostty surface.
@MainActor
@Suite(.serialized) struct TerminalBenchProbeAccountingTests {
    /// A Mac terminal that writes what the test says, when it says.
    @MainActor
    final class ScriptedSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func write(_ text: String) { handler?(.output(Data(text.utf8))) }
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the probe until a deadline
        }
    }

    @Test func probeCountsTheResetAndAnIdleEchoShowsAtOnce() async throws {
        let probe = TerminalBenchProbe()
        TerminalBenchProbe.shared = probe
        defer { TerminalBenchProbe.shared = nil }

        let session = ScriptedSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "probe")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Self.waitUntil(5) { session.handler != nil }
        try #require(session.handler != nil, "the screen never started its session")

        // The attach, as DaemonTerminalSession delivers it: the reset at the
        // attach reply, the replay (`vt-state`) in a later decoded batch, so
        // the screen feeds the reset to Ghostty on its own. Written together
        // they are one batch and the gate closes inside it.
        let reset = "\u{1B}c"
        let replay = "flood bench\r\n$ "
        session.write(reset)
        // Counted by a correct probe at once; a probe that misses it never counts it.
        try await Self.waitUntil(0.5) { probe.take().processed >= reset.utf8.count }
        session.write(replay)
        try await Self.waitUntil(3) { probe.take().processed >= replay.utf8.count }
        try await Task.sleep(for: .milliseconds(300)) // test: the replay's frames land
        #expect(probe.take().processed == reset.utf8.count + replay.utf8.count,
                "the probe missed bytes Ghostty parsed")

        // An idle keystroke and its one-byte echo, as the bench's fake daemon reports them.
        let streamEnd = reset.utf8.count + replay.utf8.count + 1
        let typed = CACurrentMediaTime()
        probe.keystroke(at: typed)
        probe.echo(count: 1, endingAt: streamEnd)
        session.write("k")
        var latencies: [Double] = []
        try await Self.waitUntil(1) {
            latencies += probe.take().echoLatencies
            return !latencies.isEmpty
        }
        let seen = CACurrentMediaTime()
        let after = probe.take()
        // Nothing is written after the echo's byte: a probe that ran behind
        // the stream (the bug) would wait for two more keystrokes and never
        // count it here. Counted, with nothing pending, is the property; how
        // many milliseconds the parse and frame took depends on the load of
        // the machine running the tests (161 ms in a full kit run), so the
        // latency is checked against the wait that saw it, not a wall clock.
        #expect(after.processed == streamEnd)
        #expect(after.pendingEchoes == 0, "the echo is still waiting for bytes that were parsed")
        let latency = try #require(latencies.first, "the echo never counted as shown")
        #expect(latencies.count == 1, "one keystroke, \(latencies.count) echo latencies")
        let waited = (seen - typed) * 1000
        #expect(latency >= 0 && latency <= waited, "echo \(latency) ms, but it was seen \(waited) ms after the keystroke")
    }

    /// The drain is timed when its last byte is parsed, not at the bench's
    /// next once-a-second sample (which read every drain as a whole second).
    @Test func drainIsTimedWhenItsLastByteIsParsed() {
        let probe = TerminalBenchProbe()
        probe.outputProcessed(100)
        let since = CACurrentMediaTime()
        probe.timeDrain(until: 300, since: since)
        probe.outputProcessed(150)
        #expect(probe.take().drainMs == nil, "250 of 300 bytes parsed: still draining")
        probe.outputProcessed(50)
        let drained = probe.take().drainMs
        let bound = (CACurrentMediaTime() - since) * 1000
        #expect(drained.map { $0 >= 0 && $0 <= bound } == true, "drain \(String(describing: drained)) ms, at most \(bound)")
        probe.outputProcessed(10)
        #expect(probe.take().drainMs == drained, "later bytes do not move a finished drain")

        let done = TerminalBenchProbe()
        done.outputProcessed(10)
        done.timeDrain(until: 10, since: CACurrentMediaTime())
        #expect(done.take().drainMs != nil, "already parsed: drained at once")
    }
}
#endif
