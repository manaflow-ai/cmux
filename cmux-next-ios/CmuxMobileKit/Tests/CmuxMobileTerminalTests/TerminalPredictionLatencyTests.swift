#if os(iOS)
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Keystroke-to-glyph latency on the phone, with and without predictive local
/// echo, through the real Ghostty surface: keys go in through the surface's
/// input path (Ghostty encodes them and writes `io_write_cb`), a fake remote
/// echoes them over an emulated link (half the round trip each way, 10 %
/// jitter, one in-order stream where a lost packet arrives a retransmit
/// timeout later and holds the ones behind it), and the echo comes back
/// through `feed`. A key is shown at the first presented Ghostty frame after
/// its echo was parsed, or, with prediction, at the Core Animation commit that
/// put its predicted glyph on screen. "Before" is the same surface with
/// prediction off.
@MainActor
@Suite(.serialized) struct TerminalPredictionLatencyTests {
    /// A line editor on the far side of the link.
    @MainActor final class Remote {
        let surface: TerminalSurfaceView
        let oneWay: Duration
        let loss: Double
        let retransmit: Duration
        private var rng: UInt64
        private var lastUp = ContinuousClock.now
        private var lastDown = ContinuousClock.now
        private var line: [UInt8] = []
        /// Echo parsed on the phone, by key index.
        var echoParsed: [Int: ContinuousClock.Instant] = [:]
        private var sentKeys = 0

        init(surface: TerminalSurfaceView, roundTrip: Duration, loss: Double, seed: UInt64) {
            self.surface = surface
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

        /// One write Ghostty encoded (one key).
        func receive(_ bytes: Data) {
            let index = sentKeys
            sentKeys += 1
            let up = arrival(after: &lastUp)
            Task { @MainActor in
                try? await Task.sleep(until: up, clock: .continuous) // test: the emulated link
                let echo = self.answer(Array(bytes))
                let down = self.arrival(after: &self.lastDown)
                try? await Task.sleep(until: down, clock: .continuous) // test: the emulated link
                self.surface.feed(Data(echo), completion: { [weak self] in self?.echoParsed[index] = .now })
            }
        }

        private func answer(_ key: [UInt8]) -> [UInt8] {
            switch key {
            case [0x0D]:
                line.removeAll()
                return Array("\r\noutput\r\n$ ".utf8)
            case [0x7F]:
                return line.popLast() == nil ? [0x07] : [0x08, 0x20, 0x08]
            case let bytes where bytes.allSatisfy({ (0x20...0x7E).contains($0) }):
                line.append(contentsOf: bytes)
                return bytes
            default:
                return []
            }
        }
    }

    /// One Core Animation commit from now: when what the main thread just
    /// changed reaches the screen.
    static func nextCommit() async -> ContinuousClock.Instant {
        await withCheckedContinuation { (done: CheckedContinuation<ContinuousClock.Instant, Never>) in
            CATransaction.setCompletionBlock { done.resume(returning: .now) }
            CATransaction.flush()
        }
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

    /// Latencies in milliseconds, one per echoed key.
    static func run(roundTripMs: Int, loss: Double, predict: Bool, seed: UInt64, diagnostics: inout [String]) async throws -> [Double] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.addSubview(surface)
        try #require(surface.surface != nil, "libghostty created no surface")
        let prediction = try #require(surface.prediction)
        _ = prediction.engine.set(enabled: predict, remote: true)
        let remote = Remote(surface: surface, roundTrip: .milliseconds(roundTripMs), loss: loss, seed: seed)
        surface.onInput = { remote.receive($0) }
        // An echo is on screen with the first Ghostty frame presented after it was parsed.
        var echoShown: [Int: ContinuousClock.Instant] = [:]
        surface.onPresent = {
            for (index, _) in remote.echoParsed where echoShown[index] == nil { echoShown[index] = .now }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            surface.feed(Data("$ ".utf8), completion: { done.resume() })
        }
        try await Task.sleep(for: .milliseconds(200)) // test: the first frame lands

        var typed: [ContinuousClock.Instant] = []
        var predictedAt: [Int: ContinuousClock.Instant] = [:]
        var rng = seed
        var noCursor = 0, held = 0, engineLayouts = 0
        var statuses: [UInt8: Int] = [:]
        for (index, key) in keys.enumerated() {
            typed.append(.now)
            let before = prediction.drawnLayout
            surface.perform([.text(key)])
            if let after = prediction.drawnLayout, after != before {
                predictedAt[index] = await nextCommit()
            }
            if predict {
                let now = TerminalSurfacePrediction.now()
                if surface.predictionCursor() == nil { noCursor += 1 }
                if prediction.engine.holdsLayout() { held += 1 }
                if prediction.engine.layout(nowUs: now, cursorColumn: Int32(surface.predictionCursor()?.column ?? 0), columns: Int32(surface.predictionCursor()?.columns ?? 0)) != nil { engineLayouts += 1 }
                statuses[prediction.engine.status(nowUs: now), default: 0] += 1
            }
            if key == "\r" {
                // A person reads the output before typing the next command.
                let deadline = ContinuousClock.now + .seconds(5)
                while echoShown[index] == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2)) // test: waits for the command's output
                }
                try await Task.sleep(for: .milliseconds(400)) // test: reading time
            } else {
                rng = rng &* 6_364_136_223_846_793_005 &+ 1
                try await Task.sleep(for: .milliseconds(90 + Int(rng >> 33) % 100)) // test: typing cadence
            }
        }

        var latencies: [Double] = []
        for (index, key) in keys.enumerated() where key != "\r" {
            let deadline = ContinuousClock.now + .seconds(10)
            while echoShown[index] == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2)) // test: waits for the echo's frame
            }
            let echo = try #require(echoShown[index], "key \(index) never showed")
            let shown = min(echo, predictedAt[index] ?? echo)
            latencies.append(milliseconds(typed[index].duration(to: shown)))
        }
        if predict {
            diagnostics.append("PREDICTION-DIAG rtt=\(roundTripMs)ms loss=\(Int(loss * 100))% predicted=\(predictedAt.count) "
                + "noCursor=\(noCursor) held=\(held) engineLayouts=\(engineLayouts) statuses=\(statuses.sorted { $0.key < $1.key }) "
                + "echoLatencyUs=\(prediction.engine.echoLatencyUs().map(String.init) ?? "nil") columns=\(surface.predictionCursor()?.columns ?? -1)")
            print(diagnostics.last ?? "")
        }
        surface.onInput = nil
        surface.onPresent = nil
        return latencies
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }

    @Test(arguments: [50, 150, 300])
    func keystrokeToGlyph(roundTripMs: Int) async throws {
        var report: [String] = []
        defer { Attachment.record(report.joined(separator: "\n"), named: "prediction-latency-\(roundTripMs)ms.txt") }
        for loss in [0.0, 0.02, 0.05] {
            var before: [Double] = []
            var after: [Double] = []
            for seed in UInt64(1)...1 {
                before += try await Self.run(roundTripMs: roundTripMs, loss: loss, predict: false, seed: seed, diagnostics: &report)
                after += try await Self.run(roundTripMs: roundTripMs, loss: loss, predict: true, seed: seed, diagnostics: &report)
            }
            func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
            report.append("PREDICTION-LATENCY rtt=\(roundTripMs)ms loss=\(Int(loss * 100))% keys=\(after.count) "
                + "p50 \(fmt(Self.percentile(before, 0.5)))->\(fmt(Self.percentile(after, 0.5))) "
                + "p95 \(fmt(Self.percentile(before, 0.95)))->\(fmt(Self.percentile(after, 0.95))) "
                + "max \(fmt(before.max() ?? 0))->\(fmt(after.max() ?? 0)) ms")
            print(report.last ?? "")
            let seen = Comment(rawValue: report.suffix(4).joined(separator: " | "))
            #expect(Self.percentile(after, 0.5) <= Self.percentile(before, 0.5), seen)
            if roundTripMs >= 150 {
                #expect(Self.percentile(after, 0.5) < Double(roundTripMs) / 2, seen)
            }
        }
    }
}
#endif
