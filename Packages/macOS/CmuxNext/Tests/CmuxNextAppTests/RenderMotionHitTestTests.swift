import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Hit testing during a render-server spring (chrome-parity p03-rendering-098, `motion.renderServer` on): the
/// hosts' frames are at rest from the change's turn while Core Animation draws them elsewhere, so a press goes
/// to the pane drawn under it, at the same place of that pane's content, and focuses that pane. Only moving
/// hosts read a presentation layer, and only while they spring; a divider grab waits for the landing.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct RenderMotionHitTestTests {
    typealias Render = SplitRenderMotionTests
    typealias Screen = CloseRenderMotionTests.Screen

    /// Three panes a | b | c, about a third of the width each.
    static let three: ScreenLayout = .splits(.split(SplitID("d1"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                    b: .split(SplitID("d2"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
    /// b | c after a closed.
    static let two: ScreenLayout = .splits(.split(SplitID("d2"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))

    /// The view AppKit sends a press at `point` (window coordinates) to.
    static func hit(_ fixture: Screen, at point: CGPoint) -> NSView? {
        fixture.root.hitTest(fixture.root.superview?.convert(point, from: nil) ?? point)
    }

    static func press(_ fixture: Screen, at point: CGPoint) throws -> NSEvent {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                    windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        try #require(event.window === fixture.window, "the event does not name the layout's window")
        return event
    }

    /// Where `layer` draws (window coordinates) at `time` into the frozen clock.
    static func drawn(_ host: PaneHostView, at time: CFTimeInterval, clock: CALayer) throws -> CGRect {
        let layer = try #require(host.layer)
        let superview = try #require(host.superview)
        let presented = try Render.presented(layer, at: time, root: clock)
        return superview.convert(superview.convertFromLayer(presented), to: nil)
    }

    /// Cmd-W on a, half way: b is drawn left of its rest, over part of c's rest frame. A press there, in b
    /// as drawn but in c at rest, reaches b's content where b shows under it, and focuses b.
    @Test func aPressMidCloseReachesThePaneDrawnUnderIt() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.three, focused: "a")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.close(to: Self.two, focus: "c")
            let b = try fixture.host("b"), c = try fixture.host("c")
            try #require(b.isOnRenderSpring && c.isOnRenderSpring, "the close is not on the render server")
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(fixture.screen.motionState.frameSpring))
            let shown = try Self.drawn(b, at: half, clock: clock)
            let cRest = c.convert(c.bounds, to: nil)
            // Inside b as drawn, inside c's rest frame, clear of b's edge.
            let x = (cRest.minX + shown.maxX) / 2
            try #require(shown.maxX - cRest.minX > 20, "b is not drawn over c's rest frame half way: \(shown) and \(cRest)")
            let point = CGPoint(x: x, y: shown.midY)
            let reads = b.presentedHitReads
            let hit = try #require(Self.hit(fixture, at: point))
            #expect(hit === b || hit.isDescendant(of: b), "the press drawn in b reached \(hit)")
            #expect(b.presentedHitReads > reads, "b's hit test did not read where it is drawn")
            // The same place of b's content as drawn: the press's distance to b's drawn left edge.
            let content = try #require(fixture.panes.contents["b"])
            let parent = try #require(b.superview)
            let restPoint = try #require(b.restPoint(ofDrawn: parent.convert(point, from: nil)))
            let inContent = content.convert(restPoint, from: parent)
            #expect(abs(inContent.x - (point.x - shown.minX - b.contentRect.minX)) < 1, "b reads the press at \(inContent)")
            let press = try Self.press(fixture, at: point)
            #expect(fixture.root.handleMonitored(press) != nil, "the press goes on to the view")
            #expect(fixture.model.focusedPane == "b", "the press focused \(String(describing: fixture.model.focusedPane))")
        }
    }

    /// Half way, the divider between b and c is drawn away from its rest and its handle is not grabbed: a press
    /// at its rest reaches what is drawn there, never a divider, until the spring lands.
    @Test func aDividerGrabWaitsForTheLanding() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.three, focused: "a")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.close(to: Self.two, focus: "c")
            // The springs reach the render server; they start from where the panes and the divider showed.
            CATransaction.flush()
            let divider = try #require(fixture.screen.dividerViews.values.first, "no divider between b and c")
            let rest = divider.convert(divider.bounds, to: nil)
            try #require(!fixture.screen.renderTracks.isEmpty, "the close is not on the render server")
            let hit = Self.hit(fixture, at: CGPoint(x: rest.midX, y: rest.midY))
            #expect(!(hit is DividerHandleView), "a press mid-spring grabbed the divider")
            // Landed: the divider takes its press again.
            #expect(await fixture.landed(), "the close did not land in 5 s")
            #expect(await fixture.renderSpringsDrained())
            let landed = Self.hit(fixture, at: CGPoint(x: rest.midX, y: rest.midY))
            #expect(landed is DividerHandleView, "after the landing a press at the divider reached \(String(describing: landed))")
        }
    }

    /// At rest no hit test reads a presentation layer, and a press goes by the frames.
    @Test func noPresentationReadAtRest() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.three, focused: "a")
            defer { fixture.close() }
            let panes: [PaneID] = ["a", "b", "c"]
            let hosts = try panes.map { try fixture.host($0) }
            for host in hosts {
                let center = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
                let hit = try #require(Self.hit(fixture, at: center))
                #expect(hit === host || hit.isDescendant(of: host), "a press at \(host.pane)'s center reached \(hit)")
            }
            #expect(hosts.allSatisfy { $0.presentedHitReads == 0 }, "a hit test at rest read a presentation layer")
            #expect(fixture.root.presentedHitReads == 0)
        }
    }

    /// A hit test mid-spring costs O(moving hosts): p99 under 0.1 ms over 1000 presses.
    @Test func aHitTestMidSpringStaysUnderABudget() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.three, focused: "a")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.close(to: Self.two, focus: "c")
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(fixture.screen.motionState.frameSpring))
            Render.seek(clock, to: half)
            let clockNow = ContinuousClock()
            var samples: [Duration] = []
            for index in 0..<1000 {
                let point = CGPoint(x: 10 + Double(index % 118) * 10, y: 400)
                let start = clockNow.now
                _ = Self.hit(fixture, at: point)
                samples.append(clockNow.now - start)
            }
            samples.sort()
            let p99 = samples[Int(Double(samples.count - 1) * 0.99)]
            #expect(p99 <= .microseconds(100), "hit test p99 \(p99)")
        }
    }
}
