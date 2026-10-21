#if os(iOS)
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// The grid cards' swipe-to-close offsets (shared by the grid and the page
/// layer, which draws the active tab's card live).
@MainActor
@Observable
final class CardSwipeState {
    /// Horizontal offset per card key, following the finger from touch-down.
    private(set) var offsets: [String: CGFloat] = [:]
    /// The part of the touch slop not caught up yet (animated to 0 over
    /// 80 ms when the drag is recognised): the card glides to the finger
    /// instead of jumping there (Safari, tabs-parity-reaudit D3).
    private(set) var catchUps: [String: CGFloat] = [:]
    /// Opacity per card key (Reduce Motion crossfades).
    private(set) var opacities: [String: Double] = [:]
    /// Lift scale per card key (1.093 while dragged).
    private(set) var scales: [String: CGFloat] = [:]

    /// Cards flying off after a committed swipe. The grid keeps drawing them
    /// (the same card view, so the exit never re-renders it) after their tab
    /// has left the list, until they are off screen.
    private(set) var departing: [DepartingCard] = []
    /// The count the grid's bar shows while a close is on its way (nil: the
    /// list's): a ✕ keeps the old count until the reflow's first frame (the
    /// frame before the cards move, as in Safari); a fling shows the new one
    /// from the release tick (or from the tick its fling became clear).
    var countHold: Int?
    /// The ✕'s reflow cue (`SafariCurveCue`; 0: none).
    private(set) var reflowCue = 0

    /// A ✕ close is about to remove a tab: hold `count` until the reflow's
    /// first frame shows (one display-link tick after its cue), or, if no
    /// card moves at all, 20 ticks.
    /// Display-link ticks from the reflow's cue (its first move) to the count.
    static let countLeadTicks = 1

    func holdCountForTapClose(_ count: Int) {
        countHold = count
        var cue = 0
        cue = SafariCurveCue.register { [weak self] in
            let clock = FrameClock()
            var ticks = 0
            clock.start { _ in
                ticks += 1
                guard ticks >= Self.countLeadTicks else { return true }
                self?.countHold = nil
                SafariCurveCue.markApplied(cue)
                if self?.reflowCue == cue { self?.reflowCue = 0 }
                return false
            }
        }
        reflowCue = cue
        let fallback = FrameClock()
        var frames = 0
        fallback.start { _ in
            frames += 1
            guard frames >= 20 else { return true }
            SafariCurveCue.fire(cue)
            return false
        }
    }
    /// The card whose long-press menu is open: it hides under its lifted
    /// preview (the grid and the layer that draws the active card).
    var menuCard: String?
    func menuChanged(_ key: String, _ open: Bool) {
        if open { menuCard = key } else if menuCard == key { menuCard = nil }
    }
    func isDeparting(_ key: String) -> Bool { departing.contains { $0.id == key } }

    func offset(_ key: String) -> CGFloat { (offsets[key] ?? 0) + (catchUps[key] ?? 0) }
    func opacity(_ key: String) -> Double { opacities[key] ?? 1 }
    func scale(_ key: String) -> CGFloat { scales[key] ?? 1 }
    /// Cards above every other card: from touch-down until their spring back
    /// or exit has finished (a lowered card slid under its neighbour while
    /// still springing back).
    private(set) var raised: Set<String> = []
    func isRaised(_ key: String) -> Bool { raised.contains(key) }
    var raisedCards: Set<String> { raised }

    /// Whether the grid lists `key` again (a refused close put it back).
    @ObservationIgnored var isListed: (String) -> Bool = { _ in false }
    /// Times the tab's removal during a fly-off (injected for tests).
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()

    /// The textbook spring for `s` (SwiftUI's `.spring(response:dampingFraction:)`
    /// renders faster and stiffer than its parameters; tabs-parity-reaudit D8).
    private func spring(_ s: ZoomSpring) -> Animation { s.animation() }

    func track(_ key: String, translation: CGFloat, reduceMotion: Bool, cardWidth: CGFloat = 0,
               onFling: @escaping (Bool) -> Void = { _ in }) {
        if !raised.contains(key) { raised.insert(key) }
        // The finger's velocity (smoothed over the pan's events): the card
        // leads a leftward finger by it (`CardSwipe.leadTime`).
        let now = CACurrentMediaTime()
        if let p = lastTrack[key], now > p.time {
            let v = (translation - p.translation) / CGFloat(now - p.time)
            velocities[key] = ((velocities[key] ?? v) + v) / 2
        }
        lastTrack[key] = (now, translation)
        // A clear fling decides now (the count), as Safari's does.
        let flinging = cardWidth > 0 && (velocities[key] ?? 0) < -CardSwipe.flingCountSpeed
            && CardSwipe.commits(offset: CardSwipe.offset(translation: translation), velocity: velocities[key] ?? 0, cardWidth: cardWidth)
        if flinging, flings[key] == nil {
            flings[key] = onFling
            // Shown `flingCountTicks` frames on, if it still reads as a fling.
            let clock = FrameClock()
            var ticks = 0
            clock.start { [weak self] _ in
                ticks += 1
                guard ticks >= CardSwipe.flingCountTicks else { return true }
                if self?.flings[key] != nil { onFling(true) }
                return false
            }
        } else if !flinging, let undo = flings.removeValue(forKey: key) {
            undo(false)
        }
        // A slow drag only: a flick's card trails the finger (Safari's holds
        // where the finger lifted), and a lead made the fling 15 % slow.
        let v = velocities[key] ?? 0
        let lead = translation < 0 && v > -CardSwipe.leadMaxSpeed ? max(-CardSwipe.leadMax, min(0, v * CardSwipe.leadTime)) : 0
        let target = CardSwipe.offset(translation: translation + lead)
        fingers[key] = CardSwipe.offset(translation: translation)
        // Still in the slot until the finger is out of Safari's onset travel.
        if !reduceMotion, followers[key] == nil, offsets[key] == nil, abs(translation) < CardSwipe.onsetTravel { return }
        if !reduceMotion, scales[key] == nil {
            withAnimation(spring(CardSwipe.lift)) { scales[key] = CardSwipe.liftScale }
        }
        opacities[key] = nil
        if reduceMotion {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { offsets[key] = target }
            return
        }
        // Safari's card follows the finger on a quick spring: it glides over
        // the touch slop at the start (-2, -8, -15, -22 pt in its first
        // frames) and carries about 4 pt past the finger when it stops
        // (re-audit 3 D3: ours jumped, then stood still, and never carried).
        var f = followers[key] ?? Follower(position: offsets[key] ?? 0)
        f.target = target
        followers[key] = f
        followClock.start { [weak self] now in self?.stepFollowers(now) ?? false }
    }

    /// A card following the finger (`CardSwipe.follow`).
    private struct Follower {
        var position: CGFloat
        var velocity: CGFloat = 0
        var target: CGFloat = 0
        var last: CFTimeInterval?
    }
    private var followers: [String: Follower] = [:]
    /// Where the finger is (the card's target), per dragged card.
    private var fingers: [String: CGFloat] = [:]
    /// The pan's last event and the finger's velocity, per dragged card.
    private var lastTrack: [String: (time: CFTimeInterval, translation: CGFloat)] = [:]
    private var velocities: [String: CGFloat] = [:]
    /// Cards whose swipe already reads as a fling (and how to take it back).
    private var flings: [String: (Bool) -> Void] = [:]
    @ObservationIgnored private let followClock = FrameClock()

    private func stepFollowers(_ now: CFTimeInterval) -> Bool {
        let w = 2 * Double.pi / CardSwipe.follow.response, z = CardSwipe.follow.damping
        var t = Transaction()
        t.disablesAnimations = true
        for (key, var f) in followers {
            let dt = min(0.05, f.last.map { now - $0 } ?? 1.0 / 60)
            f.last = now
            var rem = dt
            while rem > 0 {
                let h = min(rem, 1.0 / 600)
                let a = -w * w * Double(f.position - f.target) - 2 * z * w * Double(f.velocity)
                f.velocity += CGFloat(a * h)
                f.position += f.velocity * CGFloat(h)
                rem -= h
            }
            followers[key] = f
            withTransaction(t) { offsets[key] = f.position }
        }
        return !followers.isEmpty
    }

    /// Stops following and returns the card's offset and velocity.
    private func stopFollowing(_ key: String) -> CGFloat? {
        guard let f = followers.removeValue(forKey: key) else { return nil }
        return f.velocity
    }

    /// Release: fly off and close, or spring back. A committed card keeps
    /// going left at the release speed (at least `CardSwipe.flyOffMinSpeed`),
    /// lifted and opaque, from the release frame until it is past the
    /// screen edge; at release `close` takes its tab out of the grid (the
    /// count changes, the grid reflows) without waiting for the host.
    /// Refused: the card comes back to its slot. A card that springs back
    /// keeps the finger's velocity into the spring. With Reduce Motion
    /// nothing slides after release: the card fades out where it is, or
    /// reappears at its slot with a 0.18 s fade.
    func release(_ key: String, velocity: CGFloat, card: CGRect, reduceMotion: Bool,
                 departing makeCopy: () -> DepartingCard, onCommit: () -> Void = {}, close: @escaping () async -> Bool) {
        // The close decision reads the finger (the card may still be gliding
        // onto it, or not out of its onset travel yet).
        let finger = fingers.removeValue(forKey: key) ?? offsets[key] ?? 0
        lastTrack[key] = nil
        velocities[key] = nil
        _ = stopFollowing(key)
        let fling = flings.removeValue(forKey: key)
        guard CardSwipe.commits(offset: finger, velocity: velocity, cardWidth: card.width) else {
            fling?(false)
            comeBack(key, velocity: velocity, reduceMotion: reduceMotion)
            return
        }
        // The release tick decides: the count changes now (Safari +5-12 ms).
        onCommit()
        departing.removeAll { $0.id == key }
        departing.append(makeCopy())
        let finish: (Bool) -> Void = { [weak self] closed in
            guard let self, !closed else { return }
            // Refused: the tab is back in the grid; its card returns to the slot.
            self.departing.removeAll { $0.id == key }
            self.comeBack(key, velocity: 0, reduceMotion: reduceMotion)
        }
        let landed: () -> Void = { [weak self] in
            guard let self, self.isDeparting(key) else { return }
            self.departing.removeAll { $0.id == key }
            // Gone for good unless a refusal brings the tab back (comeBack).
            if !self.isListed(key) {
                self.offsets[key] = nil
                self.catchUps[key] = nil
                self.opacities[key] = nil
                self.scales[key] = nil
                self.raised.remove(key)
            }
        }
        if reduceMotion {
            Task { finish(await close()) }
            withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade)) { opacities[key] = 0 } completion: { landed() }
            return
        }
        // The slop catch-up ends where it is; the move is one straight line
        // at the release speed, split where the tab leaves the grid.
        let start = self.offset(key)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            catchUps[key] = nil
            offsets[key] = start
        }
        let target = CardSwipe.flyOffOffset(cardMinX: card.minX, cardWidth: card.width)
        // Driven on the display clock from the release time along Safari's
        // own fling (it holds 2 frames, accelerates and slows to the edge;
        // a constant speed left 120-210 ms early, re-audit 3 D1), scaled to
        // this card's distance to the screen edge.
        // The curve's clock starts at the finger's end, which the pan reports
        // about 3 frames late (measured against Safari with the same input,
        // once the card ends past the edge: 2.5 left the tail 12 ms early);
        // the card leaves from where it is shown.
        flights[key] = Flight(start: start, target: target, t0: CACurrentMediaTime() - 3.0 / 60, landed: landed)
        flightLink.start { [weak self] now in self?.stepFlights(now) ?? false }
        // The tab leaves the grid one frame after the release (Safari's count
        // changes about 10 ms after it, re-audit 2 D10): the fly-off's first
        // frame commits before the removal's layout and reflow (in the same
        // update they held the card still for 2-3 frames). The same card view
        // keeps flying after its tab has left.
        let clock = self.clock
        // With no delay the tab leaves in this turn (a sleep of zero still
        // waited a frame: the count changed about 50 ms after the finger
        // lifted, Safari's 5-12 ms; re-audit 4 D10).
        Task {
            if CardSwipe.flyOffRemovalDelay > .zero { try? await clock.sleep(for: CardSwipe.flyOffRemovalDelay) }
            finish(await close())
        }
    }

    private struct Flight {
        let start: CGFloat
        let target: CGFloat
        let t0: CFTimeInterval
        let landed: () -> Void
    }
    private var flights: [String: Flight] = [:]
    @ObservationIgnored private let flightLink = FrameClock()

    /// One display frame of every fly-off; false when none is left.
    private func stepFlights(_ now: CFTimeInterval) -> Bool {
        var t0 = Transaction()
        t0.disablesAnimations = true
        for (key, f) in flights {
            guard isDeparting(key) else { flights[key] = nil; continue }
            let t = now - f.t0
            let x = f.start + (f.target - f.start) * CGFloat(SafariCurve.fling.value(at: t))
            withTransaction(t0) { offsets[key] = x }
            if t >= SafariCurve.fling.duration {
                flights[key] = nil
                f.landed()
            }
        }
        return !flights.isEmpty
    }

    func cancel(_ key: String, reduceMotion: Bool) {
        _ = stopFollowing(key)
        fingers[key] = nil
        lastTrack[key] = nil
        velocities[key] = nil
        flings.removeValue(forKey: key)?(false)
        comeBack(key, velocity: 0, reduceMotion: reduceMotion)
    }

    /// Back to the card's slot: the snap-back spring carrying the finger's
    /// velocity (Safari's card keeps moving 1–2 frames after a slow release)
    /// and the settle spring, or (Reduce Motion) a 0.18 s fade in at the
    /// slot with no movement.
    private func comeBack(_ key: String, velocity: CGFloat, reduceMotion: Bool) {
        // A refused or taken-back fling: the count is the list's again.
        if reflowCue == 0 { countHold = nil }
        let from = offset(key)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            catchUps[key] = nil
            offsets[key] = from
        }
        if reduceMotion {
            withTransaction(t) {
                offsets[key] = 0
                scales[key] = nil
                opacities[key] = 0
            }
            withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade), completionCriteria: .removed) { opacities[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 { self?.raised.remove(key) }
            }
        } else {
            // Safari's own spring back replayed from the turnaround, after a
            // left drag (cmux-next re-audit 3 3g) and a right one (3i).
            let animation: Animation = .safari(from > 0 ? .snapBackRight : .snapBack)
            withAnimation(animation, completionCriteria: .removed) {
                offsets[key] = 0
                opacities[key] = 1
            } completion: { [weak self] in
                // Lowered only once it is back in its slot (a new drag may
                // have started meanwhile: then it stays raised).
                if self?.offsets[key] == 0 { self?.raised.remove(key) }
            }
            withAnimation(spring(CardSwipe.settle)) { scales[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 { self?.scales[key] = nil }
            }
        }
    }
}

extension ZoomSpring {
    /// A damped oscillator with this response and damping (mass 1,
    /// stiffness (2π / response)², damping 4π · damping / response).
    func animation(initialVelocity: Double = 0) -> Animation {
        let w = 2 * Double.pi / response
        return .interpolatingSpring(mass: 1, stiffness: w * w, damping: 2 * damping * w, initialVelocity: initialVelocity)
    }
}

/// A display link that calls `tick` with the frame's target time until it
/// returns false.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var tick: ((CFTimeInterval) -> Bool)?

    func start(_ tick: @escaping (CFTimeInterval) -> Bool) {
        self.tick = tick
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func frame(_ l: CADisplayLink) {
        if tick?(l.targetTimestamp) != true {
            l.invalidate()
            link = nil
            tick = nil
        }
    }
}

/// A swiped card on its way off screen, drawn by the grid after its tab
/// has left the list.
struct DepartingCard: Identifiable {
    let id: String
    let tab: TabsKitTab
    let rect: CGRect
}

enum CardSwipePhase {
    case changed(translation: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled
}

/// A horizontal pan on a card: begins only when the drag is more
/// horizontal than vertical, so a vertical drag still scrolls the grid.
struct CardSwipeGesture: UIGestureRecognizerRepresentable {
    var onPhase: (CardSwipePhase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        // From touch-down, not from recognition: the pan's own translation
        // drops the slop (about 14 pt behind the finger; Safari's card
        // catches it up, tabs-parity-audit 3e). Window coordinates, since
        // the card under the finger moves.
        let start = context.coordinator.touchDown ?? g.location(in: nil)
        let dx = g.location(in: nil).x - start.x
        switch g.state {
        case .began:
            CardGestures.failMenus(for: g)
            onPhase(.changed(translation: dx))
        case .changed: onPhase(.changed(translation: dx))
        case .ended: onPhase(.ended(translation: dx, velocity: g.velocity(in: g.view).x))
        case .cancelled, .failed: onPhase(.cancelled)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Where the finger went down, in window coordinates.
        var touchDown: CGPoint?

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: nil)
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// The card's long-press menu and drag-to-reorder interactions must
        /// not hold the swipe back: waiting for them to fail kept a slow
        /// drag's card still for about 300 ms, then it jumped to the finger
        /// (cmux-next tabs-parity-reaudit D3).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            CardGestures.recognizeTogether(other: other)
        }

        /// The grid's scroll view waits for this pan to fail (it fails at
        /// once for a vertical drag), so a horizontal drag is never taken by
        /// the scroller first.
        /// Never wait for the context menu's long press to fail (that held a
        /// slow drag still for about 450 ms).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

extension CardGestures {
    /// The card's swipe runs together with the system context menu's long
    /// press and its drag (Safari), never with the grid's scroll.
    static func recognizeTogether(other: UIGestureRecognizer) -> Bool {
        !(other.view is UIScrollView)
    }

    /// The swipe has moved past the slop: the context menu (and its lift)
    /// must not begin for this touch. Every other long press on the card's
    /// views is failed by toggling it off and on.
    @MainActor static func failMenus(for pan: UIGestureRecognizer) {
        var v = pan.view
        while let view = v, !(view is UIScrollView) {
            for g in view.gestureRecognizers ?? [] where g !== pan && !(g is UIPanGestureRecognizer) && g.isEnabled {
                if g is UILongPressGestureRecognizer || String(describing: type(of: g)).contains("ContextMenu")
                    || String(describing: type(of: g)).contains("Drag") {
                    g.isEnabled = false
                    g.isEnabled = true
                }
            }
            v = view.superview
        }
    }
}

#endif
