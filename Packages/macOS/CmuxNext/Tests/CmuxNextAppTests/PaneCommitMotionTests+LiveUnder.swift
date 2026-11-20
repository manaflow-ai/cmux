import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, an unzoom of a pane whose content goes on showing a live picture under its last frame (a
/// terminal: its surface draws its text at the pane's new size from the frame that shows the unzoom).
///
/// A window that shows through its panes would show both pictures: the last frame at the old size, and the live one
/// at the new size under it. So the last frame's view covers the live layer while it is in a window: the layer's
/// opacity is 0. The layer has the opacity that it had before again after each way out: the motion's end, a second
/// act in the motion, a motion that is cut, a view that another hand takes out of its window, and a window that
/// closes. No way out leaves the layer clear. Neither write has an animation: a fade of the live picture under the
/// last frame would show both again.
extension PaneCommitMotionTests {
    /// The live layer's opacity before the unzoom: not 1, so the value that comes back is the layer's own.
    nonisolated static let liveOpacity: Float = 0.75

    /// A layer whose opacity fades at each write that does not turn the layer's actions off: the write leaves an
    /// animation of the opacity on the layer, which ``fades(_:)`` reads.
    nonisolated final class LiveLayer: CALayer {
        override func action(forKey event: String) -> (any CAAction)? {
            event == "opacity" ? CABasicAnimation(keyPath: "opacity") : super.action(forKey: event)
        }
    }

    /// Writes `opacity` to `layer` with the layer's actions off: the write of a hand that wants no fade.
    static func write(_ opacity: Float, to layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }

    static func liveLayer() -> CALayer {
        let layer = LiveLayer()
        write(liveOpacity, to: layer)
        return layer
    }

    /// Whether an animation on `layer` changes its opacity.
    static func fades(_ layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath == "opacity" }
    }

    /// The rows' own tool: a write with the layer's actions off leaves no animation of the opacity on the live layer,
    /// and a plain write leaves one. So a row that reads no animation after a write says that the write had none.
    @Test func aPlainWriteOfTheLiveLayersOpacityShowsAsAnAnimation() {
        let live = Self.liveLayer()
        #expect(live.opacity == Self.liveOpacity && !Self.fades(live), "a write with the actions off left an animation: \(Self.look(live))")
        live.opacity = 0
        #expect(Self.fades(live), "a plain write left no animation: the rows can not tell a write that fades")
    }

    /// What `layer` shows now, for a message.
    static func look(_ layer: CALayer) -> String { "opacity \(layer.opacity), an animation of it: \(fades(layer))" }

    /// The key's own turn does not change the live layer. From the frame that begins the unzoom's move to the last
    /// frame of the move the layer is clear, with no animation of its opacity. The frame that ends the motion gives
    /// the layer the opacity that it had, with no animation, and the layer keeps it at rest.
    @Test func theLiveLayerUnderAnUnzoomsLastFrameIsClearUntilTheMotionsEnd() throws {
        let live = Self.liveLayer()
        let unzoom = try Self.unzooming(frames: 0, live: live)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        #expect(live.opacity == Self.liveOpacity, "the unzoom key's own turn changed the live layer: \(Self.look(live))")
        _ = harness.root.advanceFrame(Self.dt)
        try #require(Self.inFlight(screen) && Self.lastFrames(on: screen).count == 1,
                     "SETUP: the frame after the unzoom key does not move its pane under its last frame")
        var ticks = 0
        while Self.inFlight(screen), ticks < Commit.frames {
            #expect(live.opacity == 0 && !Self.fades(live),
                    "frame \(ticks + 1) of the motion shows the live picture under the last frame: \(Self.look(live))")
            _ = harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        try #require(Self.lastFrames(on: screen).isEmpty, "SETUP: the frame that ends the motion still shows the last frame")
        #expect(live.opacity == Self.liveOpacity && !Self.fades(live),
                "the frame that ends the motion did not give the live layer its opacity back at once: \(Self.look(live))")
        for _ in 0..<Commit.frames { _ = harness.root.advanceFrame(Self.dt) }
        #expect(live.opacity == Self.liveOpacity, "at rest after the unzoom the live layer does not have its opacity: \(Self.look(live))")
    }

    /// A second act in the unzoom's motion (the zoom key again, or a close of the pane that closes): the frame that
    /// shows that act has no last frame, and the live layer has its opacity again, with no animation.
    @Test(arguments: ["zoom again", "close"])
    func aSecondActInAnUnzoomsMotionGivesTheLiveLayerItsOpacityBack(_ act: String) throws {
        let live = Self.liveLayer()
        let unzoom = try Self.unzooming(frames: 3, live: live)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        try #require(Self.inFlight(screen) && Self.lastFrames(on: screen).count == 1,
                     "SETUP: three frames after the unzoom key its pane does not move under its last frame")
        #expect(live.opacity == 0, "three frames into the unzoom's move the live picture shows under the last frame: \(Self.look(live))")
        // The grid less p4: p3 takes the whole right half.
        let stays: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                      a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), b: .leaf("p3"))
        harness.model.apply(screens: act == "close" ? Commit.screen(stays) : Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(Self.lastFrames(on: screen).isEmpty, "SETUP: the frame that shows the second act still shows the last frame")
        #expect(live.opacity == Self.liveOpacity && !Self.fades(live),
                "the frame that shows the second act (\(act)) did not give the live layer its opacity back at once: \(Self.look(live))")
        for _ in 0..<Commit.frames { _ = harness.root.advanceFrame(Self.dt) }
        #expect(live.opacity == Self.liveOpacity, "at rest after the second act (\(act)) the live layer does not have its opacity: \(Self.look(live))")
    }

    /// The ways that cut an unzoom's motion, or take its last frame off the glass, with no frame tick.
    /// - `a window resize`, `the screen out of sight`, `the screen taken away`: the layout ends the motion.
    /// - `the pane's host out of its window`, `the last frame's view taken out`: a hand that is not the motion takes
    ///   the view out of its window.
    nonisolated static let liveCuts = ["a window resize", "the screen out of sight", "the screen taken away",
                                       "the pane's host out of its window", "the last frame's view taken out"]

    /// Directly after each cut the live layer has its opacity again, with no animation: it does not wait for a frame.
    @Test(arguments: liveCuts)
    func anUnzoomsMotionThatIsCutGivesTheLiveLayerItsOpacityBack(_ cut: String) throws {
        let live = Self.liveLayer()
        let unzoom = try Self.unzooming(frames: 3, live: live)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        var closed = false
        defer { if !closed { harness.window.closeAfterTest() } }
        try #require(Self.inFlight(screen) && Self.lastFrames(on: screen).count == 1,
                     "SETUP: three frames after the unzoom key its pane does not move under its last frame")
        #expect(live.opacity == 0, "three frames into the unzoom's move the live picture shows under the last frame: \(Self.look(live))")
        switch cut {
        case "a window resize":
            harness.window.setContentSize(NSSize(width: 1400, height: 900))
            harness.root.layoutSubtreeIfNeeded()
            try #require(screen.bounds.size == NSSize(width: 1400, height: 900), "SETUP: the screen did not take the window's new size: \(screen.bounds.size)")
        case "the screen out of sight":
            screen.settleMotion()
        case "the screen taken away":
            screen.tearDown()
        case "the pane's host out of its window":
            unzoom.host.removeFromSuperview()
        case "the last frame's view taken out":
            let view = try #require(Self.lastFrames(on: screen).first, "SETUP: the screen shows no last frame")
            view.removeFromSuperview()
        default:
            harness.window.closeAfterTest()
            closed = true
        }
        #expect(live.opacity == Self.liveOpacity && !Self.fades(live),
                "directly after \(cut) in the unzoom's move the live layer does not have its opacity: \(Self.look(live))")
    }

    /// An unzoom that shows in one frame puts no last frame over its pane, so it never clears the live layer: with
    /// the panes' move off, and when the layout ends the motion between the key's turn and the frame that shows it.
    @Test(arguments: ["the move is off", "a cancel between the key and its frame"])
    func anUnzoomThatShowsInOneFrameNeverClearsTheLiveLayer(_ why: String) throws {
        let live = Self.liveLayer()
        let unzoom = try Self.unzooming(frames: 0, moves: why != "the move is off", live: live)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        if why != "the move is off" { screen.zoomDim.end() }
        var seen = [live.opacity], covered = false
        for _ in 0..<Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            seen.append(live.opacity)
            if !Self.lastFrames(on: screen).isEmpty { covered = true }
        }
        try #require(!covered, "SETUP: the unzoom put a last frame over its pane (\(why))")
        #expect(seen.allSatisfy { $0 == Self.liveOpacity }, "an unzoom that shows in one frame (\(why)) changed the live layer's opacity: \(seen)")
        #expect(!Self.fades(live), "an unzoom that shows in one frame (\(why)) put an animation on the live layer's opacity")
    }

    /// Another hand writes the live layer's opacity while the last frame covers it: the layer keeps that value after
    /// the motion's end. The value that the layer had before the unzoom does not come back over a newer one.
    @Test func aWriteOfTheLiveLayersOpacityInTheMotionStaysAfterItsEnd() throws {
        let live = Self.liveLayer()
        let unzoom = try Self.unzooming(frames: 3, live: live)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        try #require(Self.inFlight(screen) && Self.lastFrames(on: screen).count == 1,
                     "SETUP: three frames after the unzoom key its pane does not move under its last frame")
        #expect(live.opacity == 0, "three frames into the unzoom's move the live picture shows under the last frame: \(Self.look(live))")
        Self.write(0.5, to: live)
        var ticks = 0
        while Self.inFlight(screen), ticks < Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        try #require(Self.lastFrames(on: screen).isEmpty, "SETUP: the frame that ends the motion still shows the last frame")
        #expect(live.opacity == 0.5, "the motion's end wrote over the opacity that another hand gave the live layer in the motion: \(Self.look(live))")
    }
}
