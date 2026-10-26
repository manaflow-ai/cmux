import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A split on the render server (chrome-parity p03-rendering-022a, `motion.renderServer` on): Cmd-D
/// puts every pane it moves at its rest frame in the key's turn, writing each frame once, its content told
/// its rest size once first, and Core Animation shows the panes, their chrome and the dividers springing
/// there from where they showed. No CPU spring steps, the window's MotionClock never runs for it, the
/// landing runs once, a second Cmd-D starts from what shows, a split during a CPU close stays on the CPU,
/// a pane closed mid-spring ends the motion, and with the switch off the split steps on the CPU as before.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct SplitRenderMotionTests {
    typealias Window = SplitRenderWindow

    @Test func aSplitRestsInTheKeysTurnAndSpringsOnTheRenderServer() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            try split.freeze()
            let layoutsBefore = try split.host("a").clipLayouts
            try split.content("a").sizes = []
            split.split()
            let screen = split.screen
            #expect(!screen.hasMotion, "a CPU spring is left to step")
            #expect(!split.root.driver.isRunning, "the split asked the window's MotionClock for layout frames")
            #expect(split.motion == [true], "the layout motion starts in the key's turn")
            #expect(try split.host("a").clipLayouts == layoutsBefore + 1, "a resized pane laid out more than once in the key's turn")
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                let frame = try #require(screen.paneFrames[pane])
                #expect(host.frame == frame.targetRect.pixelEdges(screen.scale), "\(pane) is not at rest after the key's turn")
                #expect(host.content.frame.size == host.contentRect.size, "\(pane)'s content is not at its rest size")
                #expect(host.isOnRenderSpring && host.isOnLayoutSpring, "\(pane) is not on its spring")
                let content = try split.content(pane)
                #expect(content.willRest.count == 1, "\(pane)'s content heard its rest size \(content.willRest.count) times")
                #expect(content.settled == 0, "\(pane) landed in the key's turn")
                // The content takes its rest size and no other (a new pane's empty start aside).
                let others = content.sizes.filter { $0 != host.contentRect.size && $0.width >= 1 && $0.height >= 1 }
                #expect(others.isEmpty, "\(pane)'s content was laid out at \(others) in the key's turn")
            }
            // Half way along the spring, each pane shows half way between where it showed and its rest.
            let half = Window.time(toProgress: 0.5, split.frameSpring)
            for pane: PaneID in ["a", "b"] {
                let layer = try split.layer(pane)
                let from = try split.presented(layer, at: 0)
                let shown = try split.presented(layer, at: half)
                #expect(Window.gap(from, layer.frame) > 100, "\(pane) does not move: \(from) to \(layer.frame)")
                let expected = Window.midpoint(from, layer.frame)
                #expect(Window.gap(shown, expected) <= 1, "\(pane) shows \(shown) half way, not \(expected)")
            }
        }
    }

    @Test func eachPanesChromeSpringsWithItsPane() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            try split.freeze()
            split.split()
            let half = Window.time(toProgress: 0.5, split.frameSpring)
            for pane: PaneID in ["a", "b"] {
                let layer = try split.layer(pane)
                let chrome = try #require(split.host(pane).chrome.layer)
                // The plane and the screen both fill the root: their layers share coordinates along x.
                for time in [0, half / 2, half] {
                    let shown = try split.presented(layer, at: time)
                    let ring = try split.presented(chrome, at: time)
                    #expect(abs(ring.minX - shown.minX) <= 0.5 && abs(ring.width - shown.width) <= 0.5,
                            "\(pane)'s chrome shows \(ring) over a pane that shows \(shown) at \(time) s")
                }
            }
        }
    }

    @Test func aSecondSplitWhileSpringingStartsFromWhatShows() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            try split.freeze()
            split.split()
            let half = Window.time(toProgress: 0.5, split.frameSpring)
            let springing = try split.layer("a")
            let before = try split.presented(springing, at: half)
            // Cmd-D on a half way, while its right edge still travels: c opens on that edge.
            split.apply(.split(SplitID("d"), axis: .horizontal, ratio: 0.5,
                               a: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("c")), b: .leaf("b")))
            #expect(!split.screen.hasMotion, "the retarget left a CPU spring to step")
            #expect(try split.host("c").isOnRenderSpring, "the second split's new pane is not on the render server")
            let after = try split.presented(springing, at: half)
            #expect(Window.gap(before, after) <= 0.5, "a jumped from \(before) to \(after) when the split retargeted")
            // c grows out of a's moving edge: the gap between them is their rest gap in every frame.
            let added = try split.layer("c")
            let restGap = added.frame.minX - springing.frame.maxX
            for time in [half, half + 0.05, half + 0.15] {
                let left = try split.presented(springing, at: time), right = try split.presented(added, at: time)
                #expect(abs((right.minX - left.maxX) - restGap) <= 1,
                        "c's leading edge \(right.minX) is off a's trailing edge \(left.maxX) at \(time) s")
            }
        }
    }

    @Test func aSplitDuringACPUCloseKeepsItsVelocityOnTheCPU() async throws {
        try await Window.withMotion {
            let three = SplitNode.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                                        b: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
            let split = Window(renderServer: true, tree: three)
            defer { split.close() }
            split.root.driver.isManual = true
            // Cmd-W on c: the close stays on the CPU (task 022b), and one frame gives its panes a velocity.
            split.apply(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            #expect(split.root.advanceFrame(1.0 / 120))
            let moving = try #require(split.screen.paneFrames["b"])
            try #require(moving.x.velocity != 0 || moving.width.velocity != 0, "the close gave b no velocity")
            // Cmd-D on a while b still slides.
            split.apply(.split(SplitID("d"), axis: .horizontal, ratio: 0.5,
                               a: .split(SplitID("f"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("g")), b: .leaf("b")))
            #expect(split.screen.renderSpringsInFlight == 0, "the split took frames the CPU still moved")
            #expect(split.screen.hasMotion, "the split does not spring on the CPU")
            let after = try #require(split.screen.paneFrames["b"])
            #expect(abs(after.rect.minX - moving.rect.minX) <= 0.01 && abs(after.rect.width - moving.rect.width) <= 0.01,
                    "b jumped from \(moving.rect) to \(after.rect)")
            #expect(after.x.velocity == moving.x.velocity && after.width.velocity == moving.width.velocity, "b lost its velocity")
            for pane: PaneID in ["a", "b", "g"] {
                #expect(try split.layer(pane).animationKeys()?.isEmpty ?? true, "\(pane) springs on the render server")
            }
        }
    }

    @Test func closingTheNewPaneMidSpringEndsTheMotion() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            split.root.driver.isManual = true
            try split.freeze()
            split.split()
            try split.seek(to: Window.time(toProgress: 0.5, split.frameSpring))
            // Cmd-W on b half way: b and its divider leave with springs that never run on.
            split.apply(.leaf("a"))
            #expect(split.screen.renderSpringsInFlight == 0, "a spring call of a pane or divider that left is still pending")
            #expect(try split.layer("a").animationKeys()?.isEmpty ?? true, "a still springs on the render server")
            var frames = 0
            while split.root.advanceFrame(1.0 / 120), frames < 600 { frames += 1 }
            #expect(frames < 600, "the close never landed")
            #expect(split.motion.last == false, "the layout motion did not end: \(split.motion)")
            #expect(!split.screen.userMotionActive)
        }
    }

    @Test func aSplitOfFractionalPointsAnnouncesItsRestOnce() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: true, width: 1001)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            try split.freeze()
            split.apply(.split(SplitID("d"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"), b: .leaf("b")))
            for pane: PaneID in ["a", "b"] {
                let heard = try split.content(pane).willRest.count
                #expect(heard == 1, "\(pane)'s content heard its rest size \(heard) times in the key's turn")
            }
        }
    }

    @Test func theSplitLandsOnce() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            split.split()
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(split.motion == [true, false], "layout motion \(split.motion)")
            #expect(split.screen.renderSpringsInFlight == 0)
            #expect(split.screen.renderMotion.tracks.isEmpty, "a landed spring kept its track")
            #expect(!split.root.driver.isRunning, "the landing asked for layout frames")
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring, "\(pane) is still on its spring")
                let settled = try split.content(pane).settled
                #expect(settled == 1, "\(pane)'s content heard \(settled) landings")
            }
        }
    }

    /// The variant takes the split, but its display draws no frames: every spring lands in the key's turn.
    @Test func aDisplayThatDrawsNoFramesLandsTheSplitInTheKeysTurn() async throws {
        try await Window.withMotion {
            DisplaySleep.asleepOverride = true
            defer { DisplaySleep.asleepOverride = nil }
            let split = Window(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen")
            split.split()
            #expect(split.motion == [true, false], "the layout motion did not start and end in the key's turn: \(split.motion)")
            #expect(!split.screen.hasMotion && !split.root.driver.isRunning)
            #expect(split.screen.renderSpringsInFlight == 0)
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring)
                #expect(host.layer?.animationKeys()?.isEmpty ?? true, "\(pane) animates on a display that draws no frames")
                #expect(host.frame == split.screen.paneFrames[pane]?.targetRect.pixelEdges(split.screen.scale))
                let settled = try split.content(pane).settled
                #expect(settled == 1, "\(pane)'s content heard \(settled) landings")
            }
        }
    }

    @Test func offTheSplitStepsOnTheCPUAsBefore() async throws {
        try await Window.withMotion {
            let split = Window(renderServer: false)
            defer { split.close() }
            split.root.driver.isManual = true
            split.split()
            #expect(split.screen.hasMotion, "the split does not spring on the CPU")
            #expect(split.screen.renderSpringsInFlight == 0)
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(!host.isOnRenderSpring)
                #expect(host.layer?.animationKeys()?.isEmpty ?? true, "\(pane) has render-server springs with the switch off")
            }
            #expect(split.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
        }
    }
}
