#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// iOS renderer audit (2026-10-26): every surface told Ghostty it was visible
/// once, at creation, and never again. A warm tab behind another (out of its
/// window, up to `GhosttyTerminalTabContent.warmLimit` of them) and every
/// terminal after the app went to the background kept rebuilding cells and
/// drawing Metal frames for each output batch nobody could see. The Mac app
/// pauses hidden surfaces (`WindowDrawPolicy`); the phone now does too:
/// output is still parsed, only drawing stops, and a reveal draws again.
///
/// Through the real Ghostty surface and its render counters.
@MainActor
@Suite(.serialized) struct TerminalSurfaceOcclusionTests {
    /// About 120 KB of numbered lines: many output batches, many frames.
    static func output(_ tag: String) -> Data {
        Data((0..<1500).map { "\(tag) line \($0) " + String(repeating: "x", count: 60) + "\r\n" }.joined().utf8)
    }

    static func feed(_ surface: TerminalSurfaceView, _ data: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            surface.feed(data, completion: { done.resume() })
        }
    }

    /// Waits until `surface` has drawn more than `count` frames, at most `limit`.
    static func framesGrow(_ surface: TerminalSurfaceView, past count: UInt64, limit: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if surface.renderedFrames > count { return true }
            try await Task.sleep(for: .milliseconds(20)) // test: polls the render counter until a deadline
        }
        return surface.renderedFrames > count
    }

    @Test func aSurfaceOutOfItsWindowDrawsNoFrames() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let shown = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let warm = TerminalSurfaceView(frame: CGRect(x: 0, y: 400, width: 390, height: 400))
        window.addSubview(shown)
        window.addSubview(warm)
        try #require(shown.surface != nil && warm.surface != nil, "libghostty created no surface")
        await Self.feed(warm, Data("ready\r\n".utf8))
        #expect(try await Self.framesGrow(warm, past: 0), "the warm surface never drew while in its window")

        // A warm tab behind another: its page leaves the window.
        warm.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(300)) // test: frames already requested land
        let warmBefore = warm.renderedFrames
        let shownBefore = shown.renderedFrames

        for chunk in 0..<4 {
            await Self.feed(shown, Self.output("shown \(chunk)"))
            await Self.feed(warm, Self.output("warm \(chunk)"))
        }
        // Control: the same output on the shown surface draws.
        #expect(try await Self.framesGrow(shown, past: shownBefore), "the shown surface drew nothing: the setup draws no frames")
        try await Task.sleep(for: .milliseconds(500)) // test: the warm surface's frames would land by now
        let drawnHidden = warm.renderedFrames - warmBefore
        #expect(drawnHidden == 0, "out of its window: \(drawnHidden) frames; shown: \(shown.renderedFrames - shownBefore)")
        // Still parsed: the last line is in the hidden surface's screen.
        #expect(warm.screenText()?.contains("warm 3 line 1499") == true)

        // Back in the window: it draws again.
        let hiddenTotal = warm.renderedFrames
        window.addSubview(warm)
        #expect(try await Self.framesGrow(warm, past: hiddenTotal), "back in its window, the surface never drew")
    }

    @Test func aSurfaceDrawsNoFramesWhileTheAppIsInTheBackground() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.addSubview(surface)
        try #require(surface.surface != nil, "libghostty created no surface")
        await Self.feed(surface, Data("ready\r\n".utf8))
        #expect(try await Self.framesGrow(surface, past: 0), "the surface never drew in the foreground")

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        try await Task.sleep(for: .milliseconds(300)) // test: frames already requested land
        let before = surface.renderedFrames
        for chunk in 0..<4 { await Self.feed(surface, Self.output("bg \(chunk)")) }
        try await Task.sleep(for: .milliseconds(800)) // test: output frames would land by now
        let drawn = surface.renderedFrames - before
        #expect(drawn == 0, "in the background: \(drawn) frames")

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        let backgroundTotal = surface.renderedFrames
        #expect(try await Self.framesGrow(surface, past: backgroundTotal), "back in the foreground, the surface never drew")
    }
}
#endif
