import Foundation

/// A critically damped spring, evaluated in closed form so a reversal can
/// start the next spring from the exact presented position and velocity.
///
/// Position relative to the target follows `(a + b·t)·e^(−ω·t)` with
/// `a = from − to` and `b = v₀ + ω·a`. Core Animation's `CASpringAnimation`
/// with mass 1, stiffness ω² and damping 2ω draws the same curve.
struct SidebarSlideSpring: Equatable {
    /// Natural frequency in rad/s. 43 lands a 240 pt slide in about 0.2 s.
    var omega: Double = 43
    /// The slide lands once it is this close to its target, in points.
    var landingTolerance: Double = 0.5

    var stiffness: Double { omega * omega }
    var damping: Double { 2 * omega }

    func position(from: Double, to: Double, velocity: Double, at time: Double) -> Double {
        let a = from - to
        let b = velocity + omega * a
        return to + (a + b * time) * exp(-omega * time)
    }

    func velocity(from: Double, to: Double, velocity: Double, at time: Double) -> Double {
        let a = from - to
        let b = velocity + omega * a
        return (b - omega * (a + b * time)) * exp(-omega * time)
    }

    /// When the slide is visually done: the remaining distance stays under
    /// the tolerance from here on.
    func landingTime(from: Double, to: Double, velocity: Double) -> Double {
        let a = from - to
        let b = velocity + omega * a
        guard abs(a) > landingTolerance || abs(b) > 0 else { return 0 }
        // The envelope |a| + |b|·t is an upper bound on the remaining
        // distance before the exponential, so stepping it is monotone.
        var time = 0.0
        while time < 1 {
            if (abs(a) + abs(b) * time) * exp(-omega * time) < landingTolerance { return time }
            time += 0.001
        }
        return 1
    }

    /// Caps a velocity heading toward `to` so the spring cannot overshoot
    /// it: a hide that overshoots 0 would pull the terminal's trailing edge
    /// in from the window edge.
    func nonOvershootingVelocity(from: Double, to: Double, velocity: Double) -> Double {
        let distance = to - from
        guard distance != 0, velocity * distance > 0 else { return velocity }
        let limit = omega * abs(distance)
        return min(abs(velocity), limit) * (distance > 0 ? 1 : -1)
    }
}

/// The toggle's state, kept pure so press sequences can be tested with a
/// fake clock. Positions are the content offset in points: 0 is the hidden
/// pose, the sidebar width is the shown pose.
///
/// Layout changes only at the wide end, so the terminal is at full width
/// whenever it moves:
/// - a hide from the docked layout commits the hidden layout at the
///   keypress, then slides from the width to 0;
/// - a show slides from 0 to the width on the hidden layout and commits the
///   docked layout when it lands;
/// - a press mid-slide only retargets the motion from where it is, carrying
///   its velocity, and commits nothing.
struct SidebarToggleSlideMachine: Equatable {
    struct Slide: Equatable {
        var from: Double
        var to: Double
        var velocity: Double
        var begin: Double
        var duration: Double
        var landsVisible: Bool
        var generation: Int
    }

    enum Effect: Equatable {
        /// Drop the docked layout now (the one terminal resize of a hide).
        case commitHiddenLayout
        /// Start or replace the motion.
        case animate(Slide)
        /// A show landed: commit the docked layout under the landed pose.
        case commitShownLayout
        /// A hide landed: drop the motion; the layout is already hidden.
        case finishHide
    }

    let spring: SidebarSlideSpring
    /// Whether the committed layout gives the sidebar its width.
    private(set) var docked: Bool
    /// Where the latest press asked the sidebar to be.
    private(set) var target: Bool
    private(set) var slide: Slide?
    private var generation = 0

    init(docked: Bool, spring: SidebarSlideSpring = SidebarSlideSpring()) {
        self.docked = docked
        self.target = docked
        self.spring = spring
    }

    /// The offset presented at `now`, or nil when nothing moves.
    func offset(at now: Double) -> Double? {
        guard let slide else { return nil }
        return spring.position(from: slide.from, to: slide.to, velocity: slide.velocity, at: now - slide.begin)
    }

    mutating func request(visible: Bool, width: Double, now: Double) -> [Effect] {
        target = visible
        let end = visible ? width : 0
        if let current = slide {
            guard current.landsVisible != visible else { return [] }
            let elapsed = now - current.begin
            let from = spring.position(from: current.from, to: current.to, velocity: current.velocity, at: elapsed)
            let velocity = spring.velocity(from: current.from, to: current.to, velocity: current.velocity, at: elapsed)
            return [.animate(startSlide(from: from, to: end, velocity: velocity, visible: visible, now: now))]
        }
        guard visible != docked else { return [] }
        if visible {
            return [.animate(startSlide(from: 0, to: end, velocity: 0, visible: true, now: now))]
        }
        docked = false
        return [.commitHiddenLayout, .animate(startSlide(from: width, to: 0, velocity: 0, visible: false, now: now))]
    }

    /// The motion with `generation` finished. Stale generations (a slide
    /// that was retargeted, or a repeated landing) do nothing.
    mutating func land(generation landed: Int) -> [Effect] {
        guard let current = slide, current.generation == landed else { return [] }
        slide = nil
        guard current.landsVisible else { return [.finishHide] }
        docked = true
        return [.commitShownLayout]
    }

    /// The slide actually started at `time` (its layout commit can take a
    /// while); later retargets measure from there.
    mutating func slideDidStart(generation started: Int, at time: Double) {
        guard slide?.generation == started else { return }
        slide?.begin = time
    }

    /// Visibility was set from outside the toggle (session restore, narrow
    /// window collapse, the instant path): any motion is abandoned.
    mutating func reset(visible: Bool) {
        docked = visible
        target = visible
        slide = nil
        generation &+= 1
    }

    private mutating func startSlide(from: Double, to: Double, velocity: Double, visible: Bool, now: Double) -> Slide {
        generation &+= 1
        let velocity = spring.nonOvershootingVelocity(from: from, to: to, velocity: velocity)
        let next = Slide(
            from: from,
            to: to,
            velocity: velocity,
            begin: now,
            duration: spring.landingTime(from: from, to: to, velocity: velocity),
            landsVisible: visible,
            generation: generation
        )
        slide = next
        return next
    }
}
