import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// The CPU's record of a pane's or divider's render-server springs: what shows at any
/// time without reading `presentation()`, so a change landing mid-motion starts from what shows.
@MainActor
struct RenderSpringTrackTests {
    static let spring = SpringParameters(response: 0.3, dampingFraction: 1)

    @Test func aSpringShowsItsOffsetAndVelocityWhenItBegins() {
        var track = RenderSpringTrack()
        track.add(offset: RectComponents(x: -120, width: 40), velocity: RectComponents(x: 300), begin: 10, parameters: Self.spring)
        let start = track.residual(at: 10)
        #expect(start.offset == RectComponents(x: -120, width: 40))
        #expect(start.velocity == RectComponents(x: 300))
    }

    @Test func aSpringRestsAndLeavesTheTrack() {
        var track = RenderSpringTrack()
        track.add(offset: RectComponents(x: 500), velocity: .zero, begin: 0, parameters: Self.spring)
        let settled = track.residual(at: 5)
        #expect(abs(settled.offset.x) < 0.001 && abs(settled.velocity.x) < 0.01)
        track.add(offset: RectComponents(y: 10), velocity: .zero, begin: 5, parameters: Self.spring)
        #expect(track.segments.count == 1, "a landed spring stays in the track")
    }

    /// A retarget adds a spring on top of the one still running: what shows is their sum, and it is the one
    /// spring from their summed state at the retarget (the render server and the CPU agree on it).
    @Test func springsAddAsOneSpringFromTheirSummedState() {
        var track = RenderSpringTrack()
        track.add(offset: RectComponents(x: 400), velocity: .zero, begin: 0, parameters: Self.spring)
        let retarget = 0.08
        let shown = track.residual(at: retarget)
        track.add(offset: RectComponents(x: -150), velocity: .zero, begin: retarget, parameters: Self.spring)
        for time in [0.1, 0.2, 0.35] {
            let sum = track.residual(at: time).offset.x
            let one = SpringValue.solve(displacement: Double(shown.offset.x - 150), velocity: Double(shown.velocity.x),
                                        time: time - retarget, parameters: Self.spring).displacement
            #expect(abs(Double(sum) - one) < 0.01, "at \(time) the track shows \(sum), one spring \(one)")
        }
    }

    @Test func aFrameAtRestPresentsWhatShowsAndKeepsItsTarget() {
        var track = RenderSpringTrack()
        track.add(offset: RectComponents(x: -80, height: 20), velocity: RectComponents(x: 900), begin: 0, parameters: Self.spring)
        let frame = AnimatedFrame(CGRect(x: 100, y: 0, width: 300, height: 200))
        let shown = track.presenting(frame, at: 0)
        #expect(shown.rect == CGRect(x: 20, y: 0, width: 300, height: 220))
        #expect(shown.targetRect == frame.targetRect)
        #expect(shown.x.velocity == 900)
    }

    /// A flipped view's y runs against its layer's: the layer's position moves the other way, at the
    /// velocity of the frame's centre.
    @Test func layerVelocityFollowsTheLayersAxes() {
        let flipped = RenderLayerAxes(x: 1, y: -1)
        let rate = flipped.velocity(RectComponents(x: 30, y: 10, width: 6, height: 4), anchor: CGPoint(x: 0.5, y: 0.5))
        #expect(rate.position == CGPoint(x: 33, y: -12))
        #expect(rate.size == CGSize(width: 6, height: 4))
    }
}
