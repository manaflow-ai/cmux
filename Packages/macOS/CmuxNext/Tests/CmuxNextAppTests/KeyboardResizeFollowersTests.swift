import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS K3 (cmux-ad 2026-11-02 P0 "pixel perfect ctrl shift hjkl"; film rk-browser-agent, feat 507438d): with a
/// Chromium page and an agent chat right of the moving divider, every Ctrl-Shift-H/L lost 5-8 refreshes of its spring.
/// The profile (rk-xtpa-browser-agent) shows the page's child window resized on every frame
/// (`CEFTabContentView.layoutContent` -> `-[NSWindow _setFrameCommon:]`) and every second frame took 9-14 ms. A divider drag
/// does not pay that: its pane contents follow the gesture (`PaneResizeGestureFollowing`: a page keeps its size and lays
/// out once at the landing). A keyboard press is the same change, so its contents must hear `true` at the press and
/// `false` once, after the press's spring landed, with the pane at its final frame; presses during the motion extend it.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeFollowersTests {
    typealias Harness = PaneResizeGestureTests.Harness

    static func press(_ harness: Harness, ratio: Double) {
        harness.root.keyboardResizeWillChange(screenContaining: "p2")
        harness.model.setSplitRatio("x", ratio: ratio, transaction: .make(), phase: .ended)
    }

    @Test func aPressTellsTheFollowerOnceAtTheStartAndOnceWhenItsSpringLanded() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let before = try #require(harness.root.context.hosts["p2"]).frame
        Self.press(harness, ratio: 0.45)
        // No sync here: a display frame may come before the observation applies the press.
        harness.frame()
        #expect(harness.provider.follower.heard == [true], "the press did not start the follow: \(harness.provider.follower.heard)")
        harness.land()
        #expect(harness.provider.follower.heard == [true, false])
        let host = try #require(harness.root.context.hosts["p2"])
        #expect(host.frame != before, "the press moved nothing")
        #expect(harness.provider.follower.frameAtEnd == host.frame, "the follower heard the end before the pane landed")
    }

    @Test func pressesDuringTheMotionKeepOneFollowUntilTheLastLands() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        Self.press(harness, ratio: 0.45)
        for _ in 0..<4 { harness.root.syncWithModel(); harness.frame() }
        Self.press(harness, ratio: 0.5)
        for _ in 0..<4 { harness.root.syncWithModel(); harness.frame() }
        Self.press(harness, ratio: 0.45)
        harness.land()
        #expect(harness.provider.follower.heard == [true, false])
        let host = try #require(harness.root.context.hosts["p2"])
        #expect(harness.provider.follower.frameAtEnd == host.frame)
    }
}
