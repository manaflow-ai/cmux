public import AppKit
import SwiftUI
public import CmuxNextDesignTokens

/// The Motion animations that opted in to settling at sleep
/// (`MotionGate.animate(_:in:_:settleAtSleep:completion:)`) and are still running.
///
/// A sleeping display draws no frame, so a running `animator()` change stops
/// where it is: a sidebar row opening stays half faded, and a closing row's
/// completion (which removes it) never runs. When the display goes to sleep,
/// or wakes after a change froze in the gap, ``finish()`` runs each running
/// entry's settle (which applies the current target) in a zero-length group,
/// then its completion.
///
/// A completion runs exactly once, whoever gets there first: ``finish()`` or
/// AppKit. An entry past its expected end plus ``expirySlack`` is no longer
/// settled, but AppKit's completion for it still runs.
@MainActor
enum MotionInFlight {
    private final class Entry {
        let settle: @MainActor () -> Void
        let completion: (@MainActor @Sendable () -> Void)?
        let deadline: TimeInterval
        var done = false

        init(settle: @escaping @MainActor () -> Void, completion: (@MainActor @Sendable () -> Void)?, deadline: TimeInterval) {
            self.settle = settle
            self.completion = completion
            self.deadline = deadline
        }

        func complete() {
            guard !done else { return }
            done = true
            completion?()
        }
    }

    private static var entries: [Entry] = []

    /// Seconds past its expected end before an entry stops being settled.
    /// Tests shorten it to expire entries at once.
    static var expirySlack: TimeInterval = 2

    /// Records a change about to animate for `seconds`, and returns the
    /// completion to hand AppKit in place of `completion`.
    static func track(settle: @escaping @MainActor () -> Void, seconds: TimeInterval,
                      completion: (@MainActor @Sendable () -> Void)?) -> @MainActor @Sendable () -> Void {
        // Starts the sleep watch with the first change that could need it.
        _ = DisplaySleep.shared
        let now = ProcessInfo.processInfo.systemUptime
        entries.removeAll { $0.done || $0.deadline < now }
        let entry = Entry(settle: settle, completion: completion, deadline: now + seconds + expirySlack)
        entries.append(entry)
        return {
            entries.removeAll { $0 === entry }
            entry.complete()
        }
    }

    /// Ends every running entry now: its settle, then its completion.
    static func finish() {
        let now = ProcessInfo.processInfo.systemUptime
        let running = entries.filter { !$0.done && $0.deadline >= now }
        entries = []
        guard !running.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for entry in running { entry.settle() }
        }
        for entry in running { entry.complete() }
    }
}

extension MotionGate {
    /// ``animate(_:in:_:completion:)`` for a change that must not stay
    /// half done when the display goes to sleep mid-animation (no frame
    /// draws, so it would never end). Then, or when the display wakes,
    /// `settleAtSleep` runs in a zero-length group and `completion` runs at
    /// once (``MotionInFlight``). `settleAtSleep` applies the CURRENT
    /// target, read when it runs, never the values captured by `changes`: a
    /// newer change may have moved things since.
    public func animate(_ token: MotionSpring, in view: NSView? = nil, _ changes: () -> Void,
                               settleAtSleep: @escaping @MainActor () -> Void,
                               completion: (@MainActor @Sendable () -> Void)? = nil) {
        animateSpring(token, in: view, changes, settleAtSleep: settleAtSleep, completion: completion)
    }

    /// Tracks a `token` move that runs on the render server (additive springs from
    /// ``springAnimation(_:_:from:to:)``, not an `animator()` change) the way
    /// ``animate(_:in:_:settleAtSleep:completion:)`` tracks an AppKit one: when the display goes
    /// to sleep, or wakes after the move froze in the gap, `settleAtSleep` runs, then
    /// `completion`. Call the returned closure when the move ends (its transaction's completion
    /// block); `completion` runs once, whoever gets there first. An entry ends by itself
    /// ``MotionInFlight/expirySlack`` past the springs' settling time.
    public func trackMove(_ token: MotionSpring, settleAtSleep: @escaping @MainActor () -> Void,
                          completion: (@MainActor @Sendable () -> Void)? = nil) -> @MainActor @Sendable () -> Void {
        MotionInFlight.track(settle: settleAtSleep, seconds: animatesMovement ? spring(token).settlingTime(within: 0.002) : 0,
                             completion: completion)
    }

    func animateSpring(_ token: MotionSpring, in view: NSView?, _ changes: () -> Void,
                                      settleAtSleep: (@MainActor () -> Void)?,
                                      completion: (@MainActor @Sendable () -> Void)?) {
        guard canAnimate(in: view) else { return snap(changes, completion: completion) }
        guard animatesMovement else { return withoutAnimation(changes, completion: completion) }
        let spring = self.spring(token)
        let animation = Animation.spring(response: spring.response, dampingFraction: spring.dampingFraction, blendDuration: 0)
        let finished = traced("appkit.\(token.rawValue)", completion)
        let done = settleAtSleep.map { MotionInFlight.track(settle: $0, seconds: self.duration(token), completion: finished) } ?? finished
        guard #available(macOS 15, *) else {
            // macOS 14 has no SwiftUI-animation NSAnimationContext: the timed curve, not retargetable.
            return runTimed(self.duration(token), changes, completion: done)
        }
        NSAnimationContext.animate(animation, changes: changes, completion: done)
    }
}
