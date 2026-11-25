#if os(iOS)
import QuartzCore
import UIKit

/// Moves a list's offset to its newest end on a critically damped spring, one step per display
/// frame (verify/paged-list.md, "New rows at the newest end"): the way Messages slides a new message
/// up from under the composer. The target is read every frame, so a row that grows, another row
/// that arrives or the keyboard mid-flight retarget it without a seam (position and velocity carry
/// over). A finger resting on the list holds it where it is, and it carries on when the finger lifts;
/// a drag stops it. It never fights the finger, and never leaves a model value that disagrees with
/// what is drawn (a UIView animation of the offset would).
@MainActor
final class PagedListScrollSpring {
    /// Where the offset is headed, read each frame.
    var target: () -> CGFloat = { 0 }
    /// Where the offset is now, read each frame: a correction made between frames (the list keeping
    /// its rows in place as another row lands) moves the spring with it instead of being undone.
    var current: (() -> CGFloat)?
    /// A finger rests on the list (touching, not dragging): the spring waits where it is.
    var holds: () -> Bool = { false }
    /// Sets the offset (the list marks it as its own move).
    var apply: (CGFloat) -> Void = { _ in }
    /// The slide reached its target, after this many display frames.
    var finished: (_ frames: Int) -> Void = { _ in }
    /// The list follows its newest row (the slide is pinned to the newest edge), read each frame.
    var pinned: () -> Bool = { false }
    /// The list's visible height, read each frame (the lag bound is a quarter of it).
    var viewport: () -> CGFloat = { 0 }
    /// The last step was held to the lag bound AND moved exactly as far as its goal did that frame
    /// (within half a point): the edge moved with arriving content, nothing more (the probe).
    private(set) var lastStepBounded = false
    /// The goal at the last step (the bound's check compares the step with the goal's own move).
    private var lastGoal: CGFloat?
    /// The person's jump in progress: its distance at the start, and when it started.
    private var landingFrom: (start: CGFloat, at: CFTimeInterval)?
    /// The spring is about to jump straight to its goal (no motion: Reduce Motion, or the list's motion
    /// off), which HOME-15 asks for ("slide becomes jump"): the probe does not count that frame as a push.
    var willJump: () -> Void = {}
    /// The last step's frame length (s), for the probe's push detail.
    private(set) var lastDt: Double = 0

    /// The motion token's duration: the spring settles in about this long.
    private let response: Double
    private var link: CADisplayLink?
    private var position: CGFloat = 0
    /// The offset as it read after the last step: what `current` reads beyond it was moved by
    /// someone else. (UIKit may round what it is given to the pixel; that is not a move.)
    private var applied: CGFloat?
    private var velocity: CGFloat = 0
    /// Without motion (Reduce Motion, or the screen turned it off): one jump on the first frame no
    /// finger holds it.
    private var jumps = false
    /// A finger holds it (the display link runs slowly meanwhile).
    private var held = false
    private static let sliding = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    private var lastTime: CFTimeInterval = 0
    private var frames = 0

    init(response: Double = CmuxMobileTheme.standard.motion.smooth.duration) {
        self.response = response
    }

    var isRunning: Bool { link != nil }

    /// Starts from `from` (or carries on from where it is, when running). `jump`: no motion, one
    /// jump once no finger holds it.
    /// The running slide is capped at ``maxSpeed`` (the list's own follow); a slide the person asked
    /// for (the newest-rows indicator's jump) keeps the spring's own motion.
    private(set) var capped = true

    func run(from: CGFloat, jump: Bool = false, capped: Bool = true) {
        guard link == nil else {
            // Running already: it carries on (and jumps from here if motion went away). The person's
            // jump takes over an automatic slide uncapped; an automatic one never caps theirs.
            if jump { jumps = true }
            if !capped {
                self.capped = false
                landingFrom = (abs(target() - (current?() ?? position)), CACurrentMediaTime())
            }
            return
        }
        self.capped = capped
        landingFrom = capped ? nil : (abs(target() - from), CACurrentMediaTime())
        position = from
        applied = current?()
        velocity = 0
        frames = 0
        jumps = jump
        let link = CADisplayLink(target: PagedListSpringTick(self), selector: #selector(PagedListSpringTick.tick(_:)))
        link.preferredFrameRateRange = Self.sliding
        held = false
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTime = CACurrentMediaTime()
    }

    func stop() {
        link?.invalidate()
        link = nil
        landingFrom = nil
        lastStepBounded = false
        lastGoal = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        // The frame being prepared shows at `targetTimestamp`: place the offset for that moment.
        let now = link.targetTimestamp
        let dt = min(max(now - lastTime, 0), 1.0 / 20)
        lastTime = now
        lastDt = dt
        if let current, let applied { position += current() - applied }
        if holds() {
            // A resting finger: wait where the rows are, and start again from rest when it lifts
            // (at a low frame rate meanwhile).
            velocity = 0
            applied = current?()
            if !held {
                held = true
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
            }
            return
        }
        if held {
            held = false
            link.preferredFrameRateRange = Self.sliding
        }
        frames += 1
        let goal = target()
        if jumps {
            willJump()
            finish(at: goal)
            return
        }
        let landing = landingFrom.map { (start: $0.start, elapsed: now - $0.at) }
        let next = Self.step(position: position, velocity: velocity, goal: goal, dt: dt, response: response,
                             maxSpeed: capped ? Self.maxSpeed : nil,
                             maxLag: Self.lagBound(pinned: pinned(), viewport: viewport(), landing: landing))
        let goalMove = lastGoal.map { goal - $0 } ?? 0
        lastStepBounded = next.bounded && lastGoal != nil && abs((next.position - position) - goalMove) <= 0.5
        lastGoal = goal
        if next.settled {
            finish(at: goal)
            return
        }
        position = next.position
        velocity = next.velocity
        apply(position)
        applied = current?()
    }

    /// The slide's top speed (pt/s): no frame moves it further than this times the frame's length, so
    /// whatever moves its goal (a batch of arrivals adding 100-300 pt above a `.down` list's reader) it
    /// never draws a jump; under a sustained flood it keeps sliding at this speed and its lag grows
    /// smoothly. 3000 pt/s: above the steady follow slide's p99 (2667 pt/s, max 2850, video 8c0c85fb's
    /// smooth phases), under its smallest push (86 pt in one frame, 4691 pt/s).
    static let maxSpeed: CGFloat = 3000

    /// One step of the critically damped spring toward `goal`, `dt` seconds on, capped at
    /// ``maxSpeed``: the next position and velocity, and whether it has settled (within a quarter
    /// point, nearly still). Plain data, so the step can be tested without a display link.
    static func step(position: CGFloat, velocity: CGFloat, goal: CGFloat, dt: Double, response: Double,
                     maxSpeed: CGFloat? = PagedListScrollSpring.maxSpeed)
        -> (position: CGFloat, velocity: CGFloat, settled: Bool) {
        let omega = 2 * Double.pi / response
        let x = Double(position - goal)
        let v = Double(velocity)
        let decay = exp(-omega * dt)
        let nextX = (x + (v + omega * x) * dt) * decay
        var nextV = (v - omega * (v + omega * x) * dt) * decay
        if abs(nextX) < 0.25, abs(nextV) < 4 { return (goal, 0, true) }
        var next = goal + CGFloat(nextX)
        if let maxSpeed {
            let limit = maxSpeed * CGFloat(dt)
            if abs(next - position) > limit {
                next = position + (next > position ? limit : -limit)
                nextV = Double(next > position ? maxSpeed : -maxSpeed)
            }
        }
        return (next, CGFloat(nextV), false)
    }

    /// The person's jump lands on the newest row within this long (the spring's own response).
    static let landing: Double = 0.35

    /// How far the slide may trail its goal (pt), or nil for no bound.
    /// - pinned: the list follows its newest row (the newest edge). The slide never trails it by more
    ///   than a quarter of the list (the newest-rows indicator's own threshold), so the newest row stays
    ///   in view however fast rows arrive; under a flood the spring alone settles about
    ///   speed x response / pi behind (4000 pt/s: ~445 pt, the bd734f10 pill case).
    /// - landing: the person's jump, its distance at the start and the seconds since. The bound closes
    ///   from that distance to the quarter over ``landing``, so the jump lands in time even while the
    ///   goal moves; a jump the spring makes faster on its own is not slowed.
    /// - Away from the edge: no bound (the slide runs as before).
    static func lagBound(pinned: Bool, viewport: CGFloat, landing: (start: CGFloat, elapsed: Double)?) -> CGFloat? {
        let quarter = viewport / 4
        if let landing {
            return max(quarter, abs(landing.start) * CGFloat(max(0, 1 - landing.elapsed / Self.landing)))
        }
        return pinned ? quarter : nil
    }

    /// One step with an optional bound on the lag: the step (capped at `maxSpeed`), then the position
    /// held within `maxLag` of the goal. `bounded` says the bound moved it: the edge moved with the
    /// content arriving there, not on the spring's own motion.
    static func step(position: CGFloat, velocity: CGFloat, goal: CGFloat, dt: Double, response: Double,
                     maxSpeed: CGFloat?, maxLag: CGFloat?) -> (position: CGFloat, velocity: CGFloat, settled: Bool, bounded: Bool) {
        let next = step(position: position, velocity: velocity, goal: goal, dt: dt, response: response, maxSpeed: maxSpeed)
        guard !next.settled, let maxLag, abs(next.position - goal) > maxLag else {
            return (next.position, next.velocity, next.settled, false)
        }
        return (goal + (next.position > goal ? maxLag : -maxLag), next.velocity, false, true)
    }

    private func finish(at goal: CGFloat) {
        position = goal
        apply(goal)
        stop()
        finished(frames)
    }
}

/// Breaks the display link's retain of the spring.
@MainActor
private final class PagedListSpringTick: NSObject {
    weak var spring: PagedListScrollSpring?
    init(_ spring: PagedListScrollSpring) { self.spring = spring }
    @objc func tick(_ link: CADisplayLink) {
        guard let spring else {
            link.invalidate()
            return
        }
        spring.step(link)
    }
}
#endif
