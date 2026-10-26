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

    @Test func busyOutputDrawsAtMostOneFramePerDisplayRefresh() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.addSubview(surface)
        try #require(surface.surface != nil, "libghostty created no surface")

        await Self.feed(surface, Data("ready\r\n".utf8))
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while surface.renderedFrames == 0, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20)) // test: polls the render counter until a deadline
        }
        try #require(surface.renderedFrames > 0, "the surface never drew")
        try await Task.sleep(for: .milliseconds(300)) // test: frames already requested land

        // Output batches back to back for a second, each fed once the last
        // one was parsed (the screen's output pump keeps one in flight).
        let refresh = Double(window.screen.maximumFramesPerSecond)
        let before = surface.renderedFrames
        let start = ContinuousClock.now
        var batches = 0
        while start.duration(to: .now) < .seconds(1) {
            await Self.feed(surface, Self.batch(batches))
            batches += 1
        }
        let took = start.duration(to: .now)
        let elapsed = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let frames = surface.renderedFrames - before
        let fps = Double(frames) / elapsed
        print("FRAME-PACING batches=\(batches) frames=\(frames) seconds=\(String(format: "%.3f", elapsed)) fps=\(String(format: "%.1f", fps)) display=\(Int(refresh))Hz")

        #expect(batches > Int(refresh * 2), "too few batches (\(batches)) to outrun the display: the test proves nothing")
        #expect(frames > 0, "busy output drew nothing")
        // One frame per refresh, plus the first frame after idle and a
        // little scheduling slack.
        let budget = UInt64((elapsed * refresh * 1.1).rounded(.up)) + 3
        #expect(frames <= budget, "\(frames) frames in \(elapsed) s (\(Int(fps)) per second) on a \(Int(refresh)) Hz display, \(batches) batches; at most \(budget)")
    }
}
#endif
