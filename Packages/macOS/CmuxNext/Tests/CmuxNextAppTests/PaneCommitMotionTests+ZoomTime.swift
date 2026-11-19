import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the time of the zoom key's two motions, and a second key in the zoom's move.
///
/// The zoom key is pressed again and again. Its motions end at or under 0.2 s at each speed. A motion's end is
/// the tick at which its time is spent, with 0.2 percent of the way left (`PaneCommitMotion.rest`): after it no pixel
/// changes. A shorter time is not less motion: the same panes move, and no spring passes its target.
extension PaneCommitMotionTests {
    /// The speeds at which a pane moves.
    nonisolated static let movingSpeeds: [MotionSpeed] = [.fast, .normal]

    /// The spring of `token` at `speed`, and the time after which its motion ends, by the spring's math.
    static func zoomKey(_ token: MotionSpring, at speed: MotionSpeed) -> (spring: SpringParameters, end: Double) {
        let spring = MotionPolicy(speed: speed, reduceMotion: false).spring(token)
        return (spring, spring.settlingTime(within: PaneCommitMotion.rest))
    }

    /// The zoom and the unzoom end at or under 0.2 s after the frame that shows them, at each speed.
    @Test func theZoomKeysMotionsEndWithinAFifthOfASecondAtEachSpeed() {
        for speed in Self.movingSpeeds {
            for token in [MotionSpring.zoom, MotionSpring.unzoom] {
                let end = Self.zoomKey(token, at: speed).end
                #expect(end <= 0.2, "at the speed `\(speed.rawValue)` the motion `\(token.rawValue)` ends \(end) s after its frame, later than 0.2 s")
            }
        }
    }

    /// The speed setting still orders the times, and the unzoom ends sooner than the zoom that it undoes.
    @Test func theZoomKeysMotionsKeepTheirOrder() {
        for token in [MotionSpring.zoom, MotionSpring.unzoom] {
            let fast = Self.zoomKey(token, at: .fast).end, normal = Self.zoomKey(token, at: .normal).end
            #expect(fast < normal, "the motion `\(token.rawValue)` ends after \(fast) s at `fast` and after \(normal) s at `normal`")
        }
        for speed in Self.movingSpeeds {
            let zoom = Self.zoomKey(.zoom, at: speed).end, unzoom = Self.zoomKey(.unzoom, at: speed).end
            #expect(unzoom < zoom, "at the speed `\(speed.rawValue)` the unzoom ends after \(unzoom) s and the zoom after \(zoom) s")
        }
    }

    /// No spring of the zoom key passes its target or goes back: its whole curve, read each 1/480 s to the motion's
    /// end and 0.1 s more, at each speed.
    @Test func theZoomKeysSpringsNeverPassTheirTarget() {
        for speed in Self.movingSpeeds {
            for token in [MotionSpring.zoom, MotionSpring.unzoom] {
                let (spring, end) = Self.zoomKey(token, at: speed)
                var value = SpringValue(0)
                value.target = 1
                var last: CGFloat = 0, fault = ""
                for step in 1...Int((end + 0.1) * 480) {
                    value.step(1.0 / 480.0, parameters: spring)
                    if value.value > 1 || value.value < last { fault = "step \(step): \(value.value) after \(last)" }
                    if !fault.isEmpty { break }
                    last = value.value
                }
                #expect(spring.dampingFraction >= 1 && fault.isEmpty,
                        "at the speed `\(speed.rawValue)` the spring `\(token.rawValue)` (damping \(spring.dampingFraction)) passes its target or goes back: \(fault)")
                #expect(last > 0.997, "at the speed `\(speed.rawValue)` the spring `\(token.rawValue)` is at \(last) of its way 0.1 s after its motion's end")
            }
        }
    }

    /// A second zoom key in the zoom's move, with a pane that gives its last frame (a terminal does): the pane goes
    /// on from where it shows, with the velocity that it has. The zoom's move stays on the pane's layer and the
    /// unzoom's move adds to it. The unzoom's move starts at the rect that the zoom gave the pane, so the sum of the
    /// two at the tick of the key is the place where the pane showed; and it starts with no velocity of its own, so
    /// the sum's velocity at that tick is the zoom's. The move ends with the grid alone. The dim goes on its own fade
    /// from the frame that shows the unzoom: it is gone when that fade's time is spent, which can be after the move.
    @Test func aSecondKeyInAZoomsMoveGoesOnFromThePanesPlaceAndVelocity() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        try #require(Self.inFlight(screen), "SETUP: the pane that zooms does not move three frames after the key")
        let host = try #require(harness.root.context.hosts["p4"], "SETUP: the zoomed pane has no host"), layer = try #require(host.layer)
        let content = try #require(harness.provider.contents["p4"], "SETUP: the zoomed pane has no content")
        let area = PaneContentAreaView(frame: content.bounds), picture = Picture(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        picture.autoresizingMask = [.width, .height]
        area.addSubview(picture)
        content.addSubview(area)
        let first = Set(layer.animationKeys() ?? []), placed = layer.frame
        try #require(!first.isEmpty, "SETUP: the zoom put no move on its pane's layer")

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(Self.places(zoom.grid, on: screen), "the first frame after the second key does not have the grid as its model")
        #expect(Self.inFlight(screen), "the frame that shows the unzoom has no move: the pane jumps to its place in the grid")
        let now = Set(layer.animationKeys() ?? [])
        #expect(first.isSubset(of: now), "the second key took the zoom's move off the pane's layer: its place and its velocity jump")
        let second = Self.move(of: layer, only: now.subtracting(first))
        #expect(second.moves && second.animations.allSatisfy { $0.isAdditive }, "the unzoom put no move that adds to the zoom's on the pane's layer")
        #expect(Commit.near(second.start, placed), "the unzoom's move starts at \(second.start), not at the rect that the zoom gave the pane: \(placed)")
        let springs = second.animations.compactMap { $0 as? CASpringAnimation }
        #expect(springs.count == second.animations.count && springs.allSatisfy { $0.initialVelocity == 0 },
                "the unzoom's move starts with a velocity of its own: the pane's velocity jumps at the key")

        let end = Self.toTheEnd(harness, screen)
        #expect(!Self.inFlight(screen) && zoom.grid.isShown(by: Commit.shown(screen)),
                "after the move's end the screen does not show the grid alone: \(Commit.shown(screen).panes)")
        // The dim's fade has its own time, from the frame that shows the unzoom. The unzoom's move can end before it.
        let fade = Int((screen.zoomDim.fade(on: screen) / Self.dt).rounded(.up))
        try #require(fade > 0, "SETUP: the dim has no fade on this screen")
        for _ in 0..<max(0, fade - end.ticks) { _ = harness.root.advanceFrame(Self.dt) }
        #expect(Dim.dim(harness) == nil, "\(max(fade, end.ticks)) frames after the frame that showed the unzoom (the dim's fade has \(fade)) a dim shows")
    }
}
