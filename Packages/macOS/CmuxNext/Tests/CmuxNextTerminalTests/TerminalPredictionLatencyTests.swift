import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// Keystroke-to-glyph latency in a terminal whose shell runs on another machine, with and without predictive local
/// echo, through the real session and Ghostty surface: a key goes in through the surface (`ghostty_surface_text`;
/// Ghostty encodes it and writes `io_write_cb`, where the engine sees it), the IO's writer hands it to a scripted remote
/// over an emulated link (half the round trip each way, 10 % jitter, one in-order stream where a lost packet arrives a
/// retransmit timeout later and holds the ones behind it), and the echo comes back into the surface's output lane,
/// where Ghostty parses it and then the engine sees it. A key is shown at the first frame the surface's layer presents
/// after its echo was parsed (one display refresh later when the run has no display and nothing presents), or, with
/// prediction, when the overlay draws its glyph. "Before" is the same session with the engine turned off.
@MainActor @Suite(.serialized, .enabled(if: TerminalEchoPrediction.isAvailable, "the app FFI has no prediction C ABI"))
struct TerminalPredictionLatencyTests {
    /// A line editor on the far side of the link.
    @MainActor final class Remote {
        enum Mode { case shell, password, alternateScreen }

        weak var session: TerminalSession?
        let oneWay: Duration
        let loss: Double
        let retransmit: Duration
        var mode = Mode.shell
        private var rng: UInt64
        private var lastUp = ContinuousClock.now
        private var lastDown = ContinuousClock.now
        private var line: [UInt8] = []
        private var sentKeys = 0
        /// Echo parsed by the lane, by key index, with the frames presented by then.
        var echoParsed: [Int: (at: ContinuousClock.Instant, frames: UInt64)] = [:]

        init(roundTrip: Duration, loss: Double, seed: UInt64) {
            oneWay = roundTrip / 2
            self.loss = loss
            retransmit = max(.milliseconds(200), roundTrip * 2)
            rng = seed
        }

        private func unit() -> Double {
            rng ^= rng >> 12
            rng ^= rng << 25
            rng ^= rng >> 27
            return Double((rng &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(UInt64(1) << 53)
        }

        private func arrival(after last: inout ContinuousClock.Instant) -> ContinuousClock.Instant {
            var at = ContinuousClock.now + oneWay * (0.9 + 0.2 * unit())
            while unit() < loss { at += retransmit }
            last = max(last, at)
            return last
        }

        /// One write the session's writer sent (one key).
        func receive(_ bytes: Data) {
            let index = sentKeys
            sentKeys += 1
            let up = arrival(after: &lastUp)
            Task { @MainActor in
                try? await Task.sleep(until: up, clock: .continuous) // test: the emulated link
                let echo = self.answer(Array(bytes))
                let down = self.arrival(after: &self.lastDown)
                try? await Task.sleep(until: down, clock: .continuous) // test: the emulated link
                self.feed(Data(echo), key: index)
            }
        }

        /// Output into the surface's lane, as the session's consumer hands it on; `key`'s echo is parsed once the
        /// lane ran it (the lane is serial).
        func feed(_ bytes: Data, key: Int? = nil) {
            guard let session, let lane = session.surfaceView.lane, let engine = session.echo?.engine else { return }
            lane.processOutput(bytes)
            guard let key else { return }
            lane.perform { _ in
                let parsed = (ContinuousClock.now, engine.presentedFrames)
                Task { @MainActor in self.echoParsed[key] = parsed }
            }
        }

        private func answer(_ key: [UInt8]) -> [UInt8] {
            switch key {
            case [0x0D]:
                line.removeAll()
                return mode == .shell ? Array("\r\noutput\r\n$ ".utf8) : Array("\r\n".utf8)
            case [0x7F]:
                guard mode != .password else { return [] }
                return line.popLast() == nil ? [0x07] : [0x08, 0x20, 0x08]
            case let bytes where bytes.allSatisfy({ (0x20...0x7E).contains($0) }):
                line.append(contentsOf: bytes)
                return mode == .password ? [] : bytes
            default:
                return []
            }
        }
    }

    /// The session's writer hands each write to the remote.
    nonisolated final class LinkIO: TerminalIO {
        let events: AsyncStream<TerminalIOEvent>
        private let continuation: AsyncStream<TerminalIOEvent>.Continuation
        let onWrite = Mutex<(@MainActor @Sendable (Data) -> Void)?>(nil)
        var predictsEcho: Bool { true }

        init() {
            // concurrency-allow: test IO; finite script
            (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        }

        func write(_ data: Data) async {
            guard let deliver = onWrite.withLock({ $0 }) else { return }
            await MainActor.run { deliver(data) }
        }

        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
    }

    struct Harness {
        let window: NSWindow
        let session: TerminalSession
        let io: LinkIO
        let remote: Remote
        let engine: TerminalEchoPrediction

        func close() {
            io.onWrite.withLock { $0 = nil }
            session.close()
            window.orderOut(nil)
        }
    }

    static func harness(roundTripMs: Int, loss: Double, predict: Bool, seed: UInt64) async throws -> Harness {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // runs ghostty_init and creates the app the surface needs
        let io = LinkIO()
        let session = TerminalSession(io: io, ownsGeometry: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.view.frame = window.contentLayoutRect
        window.contentView = session.view
        window.orderFront(nil)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let engine = try #require(session.echo?.engine, "a remote IO's session has no prediction engine")
        engine.set(enabled: predict, remote: true)
        let remote = Remote(roundTrip: .milliseconds(roundTripMs), loss: loss, seed: seed)
        remote.session = session
        io.onWrite.withLock { $0 = { remote.receive($0) } }
        remote.feed(Data("$ ".utf8))
        try await Task.sleep(for: .milliseconds(200)) // test: the first frame lands
        return Harness(window: window, session: session, io: io, remote: remote, engine: engine)
    }

    static let keys: [String] = {
        var keys: [String] = []
        for word in ["echo hello wrold", "\u{7F}\u{7F}\u{7F}\u{7F}", "orld", "\r", "git status --short", "\r", "ls -la ~/Projects", "\r"] {
            keys.append(contentsOf: word.map(String.init))
        }
        return keys
    }()

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// One display refresh: when an echo shows in a run with no display, where the layer presents nothing.
    static let refresh = Duration.microseconds(16_667)

    /// What one run saw, written from the main actor's callbacks.
    @MainActor final class Marks {
        var current = -1
        var predictedAt: [Int: ContinuousClock.Instant] = [:]
        var echoShown: [Int: ContinuousClock.Instant] = [:]
        var anyFrame = false
    }

    struct Run {
        var latencies: [Double] = []
        var predicted = 0
        var presentedFrames = true
        var diagnostics = ""
    }

    /// Latencies in milliseconds, one per echoed key (Return's are output, not echo, and stay out).
    static func run(roundTripMs: Int, loss: Double, predict: Bool, seed: UInt64) async throws -> Run {
        let harness = try await harness(roundTripMs: roundTripMs, loss: loss, predict: predict, seed: seed)
        defer { harness.close() }
        let (session, remote, engine) = (harness.session, harness.remote, harness.engine)
        var typed: [ContinuousClock.Instant] = []
        let marks = Marks()
        session.echo?.onDrawChange = { layout in
            guard marks.current >= 0, marks.predictedAt[marks.current] == nil, layout?.glyphs.isEmpty == false else { return }
            marks.predictedAt[marks.current] = .now // the overlay's layer commits at the end of this turn
        }
        defer { session.echo?.onDrawChange = nil }
        // An echo shows with the first frame the layer presents after it was parsed.
        let frameWatch = Task { @MainActor in
            var frames = engine.presentedFrames
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1)) // test: samples the layer's frame count
                let now = engine.presentedFrames
                if now != frames { marks.anyFrame = true }
                frames = now
                for (index, parsed) in remote.echoParsed where marks.echoShown[index] == nil {
                    if now > parsed.frames { marks.echoShown[index] = .now }
                }
            }
        }
        defer { frameWatch.cancel() }
        var rng = seed
        for (index, key) in keys.enumerated() {
            marks.current = index
            typed.append(.now)
            session.sendText(key)
            if key == "\r" {
                // A person reads the output before typing the next command.
                let deadline = ContinuousClock.now + .seconds(5)
                while remote.echoParsed[index] == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2)) // test: waits for the command's output
                }
                try await Task.sleep(for: .milliseconds(400)) // test: reading time
            } else {
                rng = rng &* 6_364_136_223_846_793_005 &+ 1
                try await Task.sleep(for: .milliseconds(90 + Int(rng >> 33) % 100)) // test: typing cadence
            }
        }
        var result = Run()
        for (index, key) in keys.enumerated() where key != "\r" {
            let deadline = ContinuousClock.now + .seconds(10)
            while remote.echoParsed[index] == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2)) // test: waits for the echo
            }
            let parsed = try #require(remote.echoParsed[index], "key \(index) never echoed")
            let echo = marks.echoShown[index] ?? (parsed.at + refresh)
            let shown = min(echo, marks.predictedAt[index] ?? echo)
            if let predicted = marks.predictedAt[index], predicted < echo { result.predicted += 1 }
            result.latencies.append(milliseconds(typed[index].duration(to: shown)))
        }
        result.presentedFrames = marks.anyFrame
        result.diagnostics = "status=\(engine.status) echoLatencyUs=\(engine.echoLatency.map(String.init) ?? "nil") "
            + "frames=\(engine.presentedFrames) predictedKeys=\(marks.predictedAt.count)"
        return result
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }

    @Test(arguments: [50, 150, 300])
    func keystrokeToGlyph(roundTripMs: Int) async throws {
        for loss in [0.0, 0.02, 0.05] {
            let before = try await Self.run(roundTripMs: roundTripMs, loss: loss, predict: false, seed: 1)
            let after = try await Self.run(roundTripMs: roundTripMs, loss: loss, predict: true, seed: 1)
            func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
            func row(_ fraction: Double) -> String {
                "\(fmt(Self.percentile(before.latencies, fraction)))->\(fmt(Self.percentile(after.latencies, fraction)))"
            }
            let report = "PREDICTION-LATENCY rtt=\(roundTripMs)ms loss=\(Int(loss * 100))% keys=\(after.latencies.count) "
                + "p50 \(row(0.5)) p95 \(row(0.95)) p99 \(row(0.99)) ms "
                + "shown-before-echo \(after.predicted)/\(after.latencies.count) "
                + "frames=\(after.presentedFrames ? "presented" : "assumed-one-refresh") \(after.diagnostics)"
            print(report)
            // Prediction never makes a key slower (5 % covers run-to-run jitter where it does not engage).
            #expect(Self.percentile(after.latencies, 0.5) <= Self.percentile(before.latencies, 0.5) * 1.05 + 1, "\(report)")
            #expect(Self.percentile(after.latencies, 0.95) <= Self.percentile(before.latencies, 0.95) * 1.05 + 1, "\(report)")
            #expect(before.predicted == 0, "\(report)")
            if roundTripMs >= 150, loss == 0 { #expect(after.predicted > 0, "\(report)") }
        }
    }

    /// Engages prediction at a shell prompt (echoed keys at 150 ms), then moves the remote to `mode` and types more:
    /// answers whether any glyph was drawn after the mode's output was parsed.
    static func drawsAfter(_ mode: Remote.Mode, entering output: String) async throws -> (drew: Bool, engaged: Bool) {
        let harness = try await harness(roundTripMs: 150, loss: 0, predict: true, seed: 7)
        defer { harness.close() }
        let (session, remote) = (harness.session, harness.remote)
        let watch = DrawWatch()
        session.echo?.onDrawChange = { layout in
            guard layout?.glyphs.contains(where: { $0.standing == .speculative }) == true else { return }
            if watch.watching { watch.drewAfter = true } else { watch.engaged = true }
        }
        defer { session.echo?.onDrawChange = nil }
        for key in "echo engaged".map(String.init) {
            session.sendText(key)
            try await Task.sleep(for: .milliseconds(120)) // test: typing cadence
        }
        try await Task.sleep(for: .milliseconds(400)) // test: the last echoes land
        remote.mode = mode
        remote.feed(Data(output.utf8))
        await session.surfaceView.lane?.drained()
        watch.watching = true
        for key in "hunter2 secret".map(String.init) {
            session.sendText(key)
            try await Task.sleep(for: .milliseconds(120)) // test: typing cadence
        }
        try await Task.sleep(for: .milliseconds(400)) // test: any late draw
        return (watch.drewAfter, watch.engaged)
    }

    @MainActor final class DrawWatch {
        var engaged = false
        var drewAfter = false
        var watching = false
    }

    @Test func noGlyphAtAPasswordPrompt() async throws {
        let result = try await Self.drawsAfter(.password, entering: "\r\nPassword: ")
        #expect(result.engaged, "prediction never engaged at the shell prompt, so the check proves nothing")
        #expect(!result.drew, "a typed password character was drawn at a no-echo prompt")
    }

    @Test func noGlyphInAnAlternateScreenProgram() async throws {
        let result = try await Self.drawsAfter(.alternateScreen, entering: "\u{1B}[?1049h\u{1B}[H\u{1B}[2J")
        #expect(result.engaged, "prediction never engaged at the shell prompt, so the check proves nothing")
        #expect(!result.drew, "a glyph was drawn over a full-screen program")
    }
}
