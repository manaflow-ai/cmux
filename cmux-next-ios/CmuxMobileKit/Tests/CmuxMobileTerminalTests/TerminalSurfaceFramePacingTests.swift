#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// iOS renderer audit follow-up (2026-10-26): libghostty had no display
/// link on iOS, so its renderer had no vsync and drew one Metal frame per
/// output batch: 190-270 frames a second on a 120 Hz iPhone under heavy
/// output (verify/terminal-flood.md), frames no screen can show. The Mac
/// renderer paces draws with a CVDisplayLink; on iOS a CADisplayLink now
/// does: a busy terminal draws at most once per display refresh.
///
/// Through the real Ghostty surface and its render counters.
@MainActor
@Suite(.serialized) struct TerminalSurfaceFramePacingTests {
    static func feed(_ surface: TerminalSurfaceView, _ data: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            surface.feed(data, completion: { done.resume() })
        }
    }

    /// One small output batch, as the daemon sends them (4 KiB events).
    static func batch(_ n: Int) -> Data {
        Data((0..<48).map { "batch \(n) line \($0) " + String(repeating: "y", count: 60) + "\r\n" }.joined().utf8)
    }

    /// Batches queued on the surface's output queue at once during the flood
    /// (about 3.4 KiB each). At 64 a loaded kit run parsed exactly 64 in the
    /// second (cmux#64874 run 46172907187): the first fill, and no completion
    /// came back to the busy main actor to refill it. 512 keeps the output
    /// queue fed through such a stall.
    static let inFlightLimit = 512

    /// Batches Ghostty parsed, counted on the output queue as it parses each.
    final class Parsed: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// Batches fed and not yet completed (their main-thread completion), and
    /// the flood loop waiting for one to complete.
    @MainActor final class InFlight {
        var count = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func completed() {
            count -= 1
            waiter?.resume()
            waiter = nil
        }
        /// Returns once the next fed batch completes; call only while `count > 0`.
        func nextCompletion() async {
            await withCheckedContinuation { waiter = $0 }
        }
    }

    @Test func busyOutputDrawsAtMostOneFramePerDisplayRefresh() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.addSubview(surface)
        try #require(surface.surface != nil, "libghostty created no surface")

        await Self.feed(surface, Data("ready\r\n".utf8))
        try await TerminalTestWait.until { surface.renderedFrames > 0 }
        try #require(surface.renderedFrames > 0, "the surface never drew")
        try await Task.sleep(for: .milliseconds(300)) // test: frames already requested land

        // Output batches back to back for a second. Up to `inFlightLimit`
        // wait on the output queue at once, so how fast Ghostty parses them
        // does not depend on how soon the main actor runs each completion:
        // feeding one batch per main-actor round trip, a full kit run (its
        // other suites on the same main actor) parsed 5 batches in the
        // second, too few to outrun the display, and the test proved nothing.
        // The flood runs at least a second and until Ghostty has parsed more
        // than two batches per display refresh it spans, so a loaded
        // simulator (64 batches in the second: cmux#64874 run 46172907187)
        // floods longer instead of failing; the frame budget below is per
        // second of the flood it actually ran.
        let refresh = Double(window.screen.maximumFramesPerSecond)
        let parsed = Parsed()
        let inFlight = InFlight()
        let before = surface.renderedFrames
        let start = ContinuousClock.now
        var fed = 0
        let floodCap = Duration.milliseconds(Int(TerminalTestWait.loadFloor * 1000))
        func outran() -> Bool {
            let ran = start.duration(to: .now)
            let seconds = Double(ran.components.seconds) + Double(ran.components.attoseconds) / 1e18
            return ran >= .seconds(1) && Double(parsed.value) > seconds * refresh * 2
        }
        while !outran(), start.duration(to: .now) < floodCap {
            if inFlight.count >= Self.inFlightLimit {
                await inFlight.nextCompletion()
                continue
            }
            inFlight.count += 1
            surface.feed(Self.batch(fed), transform: { data in
                parsed.add()
                return data
            }, completion: { inFlight.completed() })
            fed += 1
        }
        let took = start.duration(to: .now)
        let frames = surface.renderedFrames - before
        let batches = parsed.value
        // The batches still queued finish before the surface goes away.
        while inFlight.count > 0 { await inFlight.nextCompletion() }
        let elapsed = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let fps = Double(frames) / elapsed
        print("FRAME-PACING batches=\(batches) frames=\(frames) seconds=\(String(format: "%.3f", elapsed)) fps=\(String(format: "%.1f", fps)) display=\(Int(refresh))Hz")

        #expect(frames > 0, "busy output drew nothing")
        // Pacing shows only when Ghostty parses more batches than the display
        // refreshes. A host too loaded to parse that fast within the flood's
        // cap cannot tell a paced renderer from one that draws per batch: the
        // run says so in its log instead of failing on the host's load.
        guard Double(batches) > elapsed * refresh * 2 else {
            print("FRAME-PACING inconclusive: \(batches) batches in \(String(format: "%.3f", elapsed)) s do not outrun a \(Int(refresh)) Hz display (host too loaded); pacing unchecked this run")
            return
        }
        // One frame per refresh, plus the first frame after idle and a
        // little scheduling slack.
        let budget = UInt64((elapsed * refresh * 1.1).rounded(.up)) + 3
        #expect(frames <= budget, "\(frames) frames in \(elapsed) s (\(Int(fps)) per second) on a \(Int(refresh)) Hz display, \(batches) batches; at most \(budget)")
    }
}
#endif
