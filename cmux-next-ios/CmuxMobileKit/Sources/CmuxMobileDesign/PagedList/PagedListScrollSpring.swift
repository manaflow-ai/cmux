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
    func run(from: CGFloat, jump: Bool = false) {
        guard link == nil else {
            // Running already: it carries on (and jumps from here if motion went away).
            if jump { jumps = true }
            return
        }
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
    }

    fileprivate func step(_ link: CADisplayLink) {
        // The frame being prepared shows at `targetTimestamp`: place the offset for that moment.
        let now = link.targetTimestamp
        let dt = min(max(now - lastTime, 0), 1.0 / 20)
        lastTime = now
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
            finish(at: goal)
            return
        }
        let omega = 2 * Double.pi / response
        let x = Double(position - goal)
        let v = Double(velocity)
        let decay = exp(-omega * dt)
        let nextX = (x + (v + omega * x) * dt) * decay
        let nextV = (v - omega * (v + omega * x) * dt) * decay
        if abs(nextX) < 0.25, abs(nextV) < 4 {
            finish(at: goal)
            return
        }
        position = goal + CGFloat(nextX)
        velocity = CGFloat(nextV)
        apply(position)
        applied = current?()
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
