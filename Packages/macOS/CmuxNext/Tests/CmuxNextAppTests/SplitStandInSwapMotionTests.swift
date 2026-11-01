import AppKit
@testable import CmuxNextLayout
import Testing

/// Split Browser's stand-in pane grows in from the split edge as Cmd-D's pane does; the daemon's pane then takes its
/// slot under another pane id and split id (the move gives it its own). That pane started at its final frame, so it
/// jumped in mid-spring while the source still shrank: the visible "new tab, then move" step. A pane or split divider
/// that takes a gone one's slot now keeps its spring; with motion off the swap is one frame.
@MainActor
@Suite(.closesItsWindows)
struct SplitStandInSwapMotionTests {
    static let standIn = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("s"))
    static let daemons = SplitNode.split("h2", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p"))

    @Test func theDaemonsPaneKeepsTheStandInsSpring() throws {
        let screen = PaneMotionVariantTests.Screen(.leaf("p1"), variant: .standard)
        screen.context.livePanes = ["p1", "s"]
        screen.view.update(layout: .splits(Self.standIn), animated: true)
        let target = try #require(screen.view.geometry.panes["s"])
        for _ in 0..<3 { screen.step() }
        let shown = try #require(screen.view.paneFrames["s"])
        try #require(shown.rect != target && shown.x.velocity != 0, "fixture: the stand-in's spring landed already")
        let divider = try #require(screen.view.dividerFrames[.split("h")])
        try #require(divider.rect != divider.targetRect && divider.x.velocity != 0, "fixture: the divider's spring landed already")

        screen.context.livePanes = ["p1", "p"]
        screen.view.update(layout: .splits(Self.daemons), animated: true)
        // Where and how fast the stand-in moved: a pane added in place would start still, at its target.
        let taken = try #require(screen.view.paneFrames["p"])
        #expect(taken.rect == shown.rect && taken.x.velocity == shown.x.velocity, "the daemon's pane did not take the stand-in's spring")
        let dividerTaken = try #require(screen.view.dividerFrames[.split("h2")])
        #expect(dividerTaken.x.velocity == divider.x.velocity, "the daemon's split divider did not take the stand-in's spring")
        // It keeps moving between there and its target on the next frame.
        screen.step()
        let next = try #require(screen.view.paneFrames["p"]?.rect)
        #expect(next != shown.rect && next != target, "the daemon's pane did not keep springing: \(next)")
        for _ in 0..<240 { screen.step() }
        #expect(screen.view.paneFrames["p"]?.rect == target)
        #expect(!screen.step(), "the swapped pane kept requesting animation frames")
    }

    /// A guard, not a regression test (it also holds without the carried spring): with motion off the split and the
    /// swap each land in one frame and ask for no more.
    @Test func withMotionOffTheSplitAndTheSwapAreOneFrame() throws {
        let screen = PaneMotionVariantTests.Screen(.leaf("p1"), variant: .standard, reduceMotion: true)
        screen.context.livePanes = ["p1", "s"]
        screen.view.update(layout: .splits(Self.standIn), animated: true)
        let target = try #require(screen.view.geometry.panes["s"])
        #expect(screen.view.paneFrames["s"]?.rect == target, "the stand-in did not land in one frame")
        screen.context.livePanes = ["p1", "p"]
        screen.view.update(layout: .splits(Self.daemons), animated: true)
        #expect(screen.view.paneFrames["p"]?.rect == target, "the daemon's pane did not land in one frame")
        #expect(!screen.step(), "a swap with motion off asked for animation frames")
    }
}
