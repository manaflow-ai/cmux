// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxAgentCursor
import CoreGraphics
import Foundation
import QuartzCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxRemoteComputerUse

/// The living tail (``AgentCursorTail``): a pure model stepped per frame. These tests drive it
/// with the overlay's own glide plans and check what the brief asks of it: the root stays on the
/// stem, the pointer's tip never moves, motion after a stop decays back to the idle life, it is
/// bounded and never enters the pointer, Reduce Motion is the still rest pose, it never stops and
/// never loops while shown, and each session moves on its own.
///
/// With `CMUX_CURSOR_TAIL_FRAMES_DIR` set, `writeFrameSequences` draws each state frame by frame
/// (PNG per frame, 60 fps) for the review videos.
@MainActor
@Suite struct AgentCursorTailTests {
    static let fps = 120.0

    /// Pointer positions (screen points, y up) at `fps` for a glide from `from` to `to`, as the
    /// overlay's keyframes place them (linear between the plan's 1/120 s samples).
    static func glide(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let plan = GlideMotion().plan(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y, endHeading: 0)
        return plan.samples.map { CGPoint(x: $0.x, y: $0.y) }
    }

    static func hold(_ point: CGPoint, seconds: Double) -> [CGPoint] {
        Array(repeating: point, count: Int(seconds * fps))
    }

    /// Steps `tail` through `pointer` (one position per frame) and calls `check` after each frame.
    static func run(_ tail: inout AgentCursorTail, _ pointer: [CGPoint], check: (Int, AgentCursorTail) -> Void = { _, _ in }) {
        for (i, p) in pointer.enumerated() {
            tail.step(dt: 1 / fps, pointer: p)
            check(i, tail)
        }
    }

    static func length(_ points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)) }
    }

    @Test func theRootStaysOnTheStemThroughEveryKindOfMotion() {
        var tail = AgentCursorTail(session: "root", animates: true)
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 900, y: 600), c = CGPoint(x: 120, y: 700)
        let path = Self.hold(a, seconds: 1) + Self.glide(from: a, to: b) + Self.hold(b, seconds: 1)
            + Self.glide(from: b, to: c) + Self.hold(c, seconds: 2)
        var worst = 0.0
        Self.run(&tail, path) { i, tail in
            let root = tail.points[0]
            worst = max(worst, Double(hypot(root.x - AgentCursorTail.root.x, root.y - AgentCursorTail.root.y)))
        }
        #expect(worst == 0, "the root left the stem by \(worst)")
    }

    @Test func itNeverExceedsItsLengthNorEntersOrCurlsBehindThePointer() {
        var tail = AgentCursorTail(session: "bounds", animates: true)
        // A violent zig-zag: short, long and diagonal moves in every direction, with clicks,
        // typing and a droop on top.
        var random = SplitMix64(seed: 42)
        var at = CGPoint(x: 600, y: 400)
        var frames = 0, finite = true, longest = 0.0, inside = 0, behind = 0, outOfCone = 0
        for move in 0..<60 {
            let to = CGPoint(x: 50 + random.unit() * 1300, y: 50 + random.unit() * 800)
            if move % 3 == 0 { tail.click() }
            if move % 5 == 0 { tail.typing() }
            tail.drooping = move % 7 == 0
            let path = Self.glide(from: at, to: to) + Self.hold(to, seconds: random.unit() * 0.3)
            Self.run(&tail, path) { _, tail in
                frames += 1
                let points = tail.points
                finite = finite && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                longest = max(longest, Self.length(points))
                inside += points.dropFirst().filter { AgentCursorTail.pointerContains($0) }.count
                // Never curled behind the arrow: the arrow's body lies up and left of the stem.
                behind += points.dropFirst().filter { $0.x < AgentCursorTail.root.x - 0.5 && $0.y > AgentCursorTail.root.y + 0.5 }.count
                outOfCone += tail.angles.filter { !tail.tuning.directions.contains($0) }.count
            }
            at = to
        }
        #expect(frames > 3000)
        #expect(finite)
        #expect(longest <= AgentCursorTail.maxLength + 1e-9, "longest \(longest), max \(AgentCursorTail.maxLength)")
        #expect(inside == 0, "\(inside) points inside the pointer")
        #expect(behind == 0, "\(behind) points curled behind the arrow")
        #expect(outOfCone == 0, "\(outOfCone) segments pointing up into the pointer")
    }

    @Test func aStopOvershootsThenSettlesBackToTheIdleLife() {
        // Two tails of one session (the same idle wave and flicks): one makes a long move, one
        // stays. After the stop, the moved one's extra motion decays to the still one's.
        var moved = AgentCursorTail(session: "settle", animates: true)
        var still = AgentCursorTail(session: "settle", animates: true)
        let a = CGPoint(x: 100, y: 300), b = CGPoint(x: 1100, y: 300)
        let glide = Self.glide(from: a, to: b)
        moved.activity()
        still.activity()
        var peak = 0.0
        var afterStop: [Double] = []
        let path = glide + Self.hold(b, seconds: 3)
        for (i, p) in path.enumerated() {
            moved.step(dt: 1 / Self.fps, pointer: p)
            still.step(dt: 1 / Self.fps, pointer: a)
            let gap = zip(moved.angles, still.angles).map { abs($0 - $1) }.max() ?? 0
            if i < glide.count + 60 { peak = max(peak, gap) } else { afterStop.append(gap) }
        }
        // It follows the move: a real swing, not a twitch.
        #expect(peak > 0.6, "peak swing \(peak) rad")
        // 2 s after the stop it is back to the idle life (within 0.03 rad of every joint).
        let late = afterStop.suffix(Int(Self.fps * 0.5))
        #expect((late.max() ?? 1) < 0.03, "residual \(late.max() ?? -1) rad")
        // And it settles with an overshoot: the root swings past the rest pose the other way.
        var signs = Set<Bool>()
        var probe = AgentCursorTail(session: "settle-overshoot", animates: true,
                                    tuning: { var t = AgentCursorTail.Tuning(); t.waveAmplitudes = [0, 0, 0, 0]; t.flickKick = 0; return t }())
        for p in path {
            probe.step(dt: 1 / Self.fps, pointer: p)
            let dev = probe.angles[0] - AgentCursorTail.rest.absolute[0]
            if abs(dev) > 0.05 { signs.insert(dev > 0) }
        }
        #expect(signs.count == 2, "the root swings to both sides of its rest pose")
    }

    @Test func reduceMotionIsTheStillRestPose() {
        var tail = AgentCursorTail(session: "reduce", animates: false)
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 900, y: 500)
        tail.click()
        tail.typing()
        tail.drooping = true
        var moved = 0.0
        Self.run(&tail, Self.glide(from: a, to: b) + Self.hold(b, seconds: 3)) { _, tail in
            for (p, q) in zip(tail.points, AgentCursorTail.rest.points) {
                moved = max(moved, Double(hypot(p.x - q.x, p.y - q.y)))
            }
        }
        #expect(moved < 1e-9, "Reduce Motion moved the tail by \(moved)")
        // The overlay draws the exact S then (offscreen frames stand in for the screen).
        var images: [CGImage] = []
        AgentCursorOverlay.renderFrames([Scripted(session: "reduce", label: "Claude Code", start: CGPoint(x: 120, y: 90),
                                                  steps: [Self.at(0.2, .click), Self.at(0.4, .typing("hello"))])],
                                        size: CGSize(width: 240, height: 180), scale: 2, fps: 30, seconds: 1.5,
                                        animated: false) { i, image in if i == 0 || i == 44 { images.append(image) } }
        #expect(images.count == 2)
        #expect(Self.region(images[0], CGRect(x: 120, y: 90, width: 50, height: 40))
                == Self.region(images[1], CGRect(x: 120, y: 90, width: 50, height: 40)), "the still tail changed")
    }

    @Test func itIsNeverStillAndNeverLoopsWhileShown() {
        var tail = AgentCursorTail(session: "alive", animates: true)
        let at = CGPoint(x: 400, y: 400)
        var tips: [CGPoint] = []
        Self.run(&tail, Self.hold(at, seconds: 24)) { _, tail in tips.append(tail.points[AgentCursorTail.segmentCount]) }
        // Every half second of 24 s at rest, the tip moves.
        let window = Int(Self.fps / 2)
        for start in stride(from: 0, to: tips.count - window, by: window) {
            let slice = tips[start..<(start + window)]
            let xs = slice.map(\.x), ys = slice.map(\.y)
            let travel = Double((xs.max() ?? 0) - (xs.min() ?? 0) + (ys.max() ?? 0) - (ys.min() ?? 0))
            #expect(travel > 0.05, "still at \(Double(start) / Self.fps) s (moved \(travel))")
        }
        // Bounded idle life: calm, not busy (the tip stays within 6 units of its mean).
        let mean = CGPoint(x: tips.map(\.x).reduce(0, +) / CGFloat(tips.count), y: tips.map(\.y).reduce(0, +) / CGFloat(tips.count))
        #expect(tips.allSatisfy { hypot($0.x - mean.x, $0.y - mean.y) < 6 })
        // No repeat: no lag from 0.5 s to 12 s brings a 4 s stretch back within 0.05 units.
        let span = Int(4 * Self.fps)
        let base = Array(tips[Int(2 * Self.fps)..<(Int(2 * Self.fps) + span)])
        var closest = Double.infinity
        for lag in stride(from: Int(0.5 * Self.fps), through: Int(12 * Self.fps), by: 2) {
            let other = tips[(Int(2 * Self.fps) + lag)..<(Int(2 * Self.fps) + lag + span)]
            let rms = (zip(base, other).map { Double(($0.x - $1.x) * ($0.x - $1.x) + ($0.y - $1.y) * ($0.y - $1.y)) }
                .reduce(0, +) / Double(span)).squareRoot()
            closest = min(closest, rms)
        }
        #expect(closest > 0.05, "a 4 s stretch repeats within \(closest) units")
    }

    @Test func eachSessionMovesOnItsOwnAndTheSameSessionIsDeterministic() {
        func trace(_ session: String) -> [Double] {
            var tail = AgentCursorTail(session: session, animates: true)
            var out: [Double] = []
            Self.run(&tail, Self.hold(CGPoint(x: 10, y: 10), seconds: 6)) { _, tail in out.append(tail.angles[4]) }
            return out
        }
        let a = trace("claude-1"), again = trace("claude-1"), b = trace("codex-2"), c = trace("claude-3")
        #expect(a == again)
        let ab = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        let ac = zip(a, c).map { abs($0 - $1) }.max() ?? 0
        #expect(ab > 0.05 && ac > 0.05, "sessions move in step (\(ab), \(ac))")
    }

    @Test func clicksFlickTypingWigglesAndAlertsDroop() {
        /// How much the tail's tip turns (total, rad) in `seconds` after `act`, and the tail then.
        func motion(_ act: (inout AgentCursorTail) -> Void, seconds: Double = 0.6) -> (Double, AgentCursorTail) {
            var tail = AgentCursorTail(session: "react", animates: true)
            Self.run(&tail, Self.hold(.zero, seconds: 1))
            act(&tail)
            var previous = tail.angles[AgentCursorTail.segmentCount - 1]
            var total = 0.0
            Self.run(&tail, Self.hold(.zero, seconds: seconds)) { _, tail in
                total += abs(tail.angles[AgentCursorTail.segmentCount - 1] - previous)
                previous = tail.angles[AgentCursorTail.segmentCount - 1]
            }
            return (total, tail)
        }
        let (idle, _) = motion { _ in }
        let (click, _) = motion { $0.click() }
        let (typing, _) = motion { $0.typing() }
        let (_, drooped) = motion({ $0.drooping = true }, seconds: 2)
        #expect(click > idle * 2, "click \(click) vs idle \(idle)")
        #expect(typing > idle * 1.5, "typing \(typing) vs idle \(idle)")
        // Drooped: the tail hangs lower (its tip below the rest tip).
        #expect(drooped.points[AgentCursorTail.segmentCount].y < AgentCursorTail.rest.points[AgentCursorTail.segmentCount].y - 2)
    }

    @Test func itAsksForFullRateOnlyWhileStirred() {
        var tuning = AgentCursorTail.Tuning()
        tuning.flickGap = 1000...1000
        var tail = AgentCursorTail(session: "rate", animates: true, tuning: tuning)
        let at = CGPoint(x: 300, y: 300)
        Self.run(&tail, Self.hold(at, seconds: 3))
        #expect(!tail.isLively, "at rest it runs at the idle rate")
        tail.click()
        #expect(tail.isLively, "a click wants the display's full rate")
        Self.run(&tail, Self.hold(at, seconds: 2.2))
        #expect(!tail.isLively)
        var moving = false
        Self.run(&tail, Self.glide(from: at, to: CGPoint(x: 900, y: 500))) { _, tail in moving = moving || tail.isLively }
        #expect(moving, "following the pointer wants the full rate")
        Self.run(&tail, Self.hold(CGPoint(x: 900, y: 500), seconds: 2.2))
        tail.activity()
        #expect(!tail.isLively, "a step that does not move the pointer (a look) keeps the idle rate")
        let still = AgentCursorTail(session: "rate", animates: false)
        #expect(!still.isLively, "without animation it never asks for frames")
    }

    @Test func anIdleBatchIsTheSameFramesAsSteppingFrameByFrame() {
        // The overlay plays the idle life ahead in batches and, when something stirs the tail
        // mid-batch, steps a copy from the batch's start to now: both must be exactly the
        // frames the tail would have had frame by frame.
        var batched = AgentCursorTail(session: "batch", animates: true)
        var stepped = batched
        let at = CGPoint(x: 40, y: 40)
        let paths = batched.advance(frames: 120, dt: 1.0 / 60, pointer: at, speed: 1, scale: 1.3)
        #expect(paths.count == 120)
        var same = 0
        for path in paths {
            stepped.step(dt: 1.0 / 60, pointer: at, speed: 1, pointScale: 1.3)
            if stepped.path(scale: 1.3) == path { same += 1 }
        }
        #expect(same == 120)
        #expect(batched.angles == stepped.angles)
        // And it is alive: the batch's first and last frames differ.
        #expect(paths.first != paths.last)
    }

    /// The overlay's frame clock, driven with a test clock: idle long enough to play ahead, then a
    /// move step. On c2b2f4f the move only woke the tail from calm, the first frame after the stir
    /// had no time step, so the tail stayed "calm" and that very frame started a new batch: the
    /// glide played with a frozen tail. Frames here never claim the body is gliding, so only the
    /// stir and the frame rules keep the tail following.
    @Test func aMoveAfterAnIdleBatchIsFollowedFrameByFrame() {
        let scale: CGFloat = 1.3
        var driver = AgentCursorTailDriver(model: AgentCursorTail(session: "driver", animates: true))
        let a = CGPoint(x: 100, y: 300), b = CGPoint(x: 1100, y: 300)
        var t = 0.0
        var batched = false
        for _ in 0..<Int(4 * Self.fps) {
            t += 1 / Self.fps
            if case .batch(let paths) = driver.frame(at: t, pointer: a, gliding: false, scale: scale) {
                #expect(paths.count == AgentCursorTailDriver.batchFrames + 1)
                batched = true
                break
            }
        }
        #expect(batched, "a calm tail plays ahead")
        // Partway through the batch the agent's move step arrives.
        t += 0.2
        let shown = driver.stir(at: t, scale: scale) { $0.note(.move) }
        #expect(shown != nil, "ending a batch shows its current frame")
        #expect(!driver.isBatching)
        var still = driver.model
        let glide = Self.glide(from: a, to: b)
        var drawn = 0, swing = 0.0
        for (i, p) in glide.enumerated() {
            if i > 0 { t += 1 / Self.fps }
            switch driver.frame(at: t, pointer: p, gliding: false, scale: scale) {
            case .path: drawn += 1
            case .batch: Issue.record("frame \(i) after the move was played ahead, not drawn")
            }
            still.step(dt: 1 / Self.fps, pointer: a)
            swing = max(swing, zip(driver.model.angles, still.angles).map { abs($0 - $1) }.max() ?? 0)
        }
        #expect(drawn == glide.count, "every frame of the glide is drawn, the first one after the stir included")
        #expect(swing > 0.6, "the tail followed the glide (swing \(swing) rad)")
        var batchedAgain = false
        for _ in 0..<Int(5 * Self.fps) {
            t += 1 / Self.fps
            if case .batch = driver.frame(at: t, pointer: b, gliding: false, scale: scale) {
                batchedAgain = true
                break
            }
        }
        #expect(batchedAgain, "after the stop it settles, then plays ahead again")
    }

    @Test func theDriverNeverPlaysAheadMidGlideOnAWakingFrameOrWithoutAnimation() {
        var tuning = AgentCursorTail.Tuning()
        tuning.flickGap = 1000...1000
        var driver = AgentCursorTailDriver(model: AgentCursorTail(session: "rules", animates: true, tuning: tuning))
        var t = 0.0
        let at = CGPoint(x: 50, y: 50)
        // Calm (2.5 s, no flicks) but the body's glide animation runs: every frame is drawn.
        for _ in 0..<Int(2.5 * Self.fps) {
            t += 1 / Self.fps
            if case .batch = driver.frame(at: t, pointer: at, gliding: true, scale: 1.3) { Issue.record("batched while gliding") }
        }
        // The first frame after the clock (re)starts has no time step: never a batch.
        driver.stop()
        if case .batch = driver.frame(at: t, pointer: at, gliding: false, scale: 1.3) { Issue.record("batched on a waking frame") }
        t += 1 / Self.fps
        guard case .batch(let first) = driver.frame(at: t, pointer: at, gliding: false, scale: 1.3) else {
            Issue.record("a calm tail on a real frame plays ahead")
            return
        }
        // Batches chain: the next one starts from the last frame of this one and steps on.
        var next = driver.model
        guard let second = driver.batchEnded(at: t + Double(first.count - 1) / 60, scale: 1.3) else {
            Issue.record("no next batch")
            return
        }
        #expect(second.first == first.last, "the next batch starts where this one ended")
        next.step(dt: AgentCursorTailDriver.batchStep, pointer: at, speed: 1, pointScale: 1.3)
        #expect(second[1] == next.path(scale: 1.3), "and goes on one step at a time")
        // Without animation it never plays ahead.
        var off = AgentCursorTailDriver(model: AgentCursorTail(session: "rules", animates: false))
        for i in 0..<Int(3 * Self.fps) {
            if case .batch = off.frame(at: Double(i) / Self.fps, pointer: at, gliding: false, scale: 1.3) { Issue.record("batched without animation") }
        }
    }

    /// Ending a batch partway shows exactly the keyframe on screen then: keyframe k is the pose
    /// k steps after the batch's start (keyframe 0 is the start).
    @Test func endingABatchShowsTheKeyframeOnScreen() {
        var driver = AgentCursorTailDriver(model: AgentCursorTail(session: "index", animates: true))
        var t = 0.0
        var paths: [CGPath] = []
        while paths.isEmpty, t < 10 {
            t += 1 / Self.fps
            if case .batch(let batch) = driver.frame(at: t, pointer: .zero, gliding: false, scale: 1.3) { paths = batch }
        }
        #expect(paths.count == AgentCursorTailDriver.batchFrames + 1)
        for k in [0, 1, 7, AgentCursorTailDriver.batchFrames] {
            var copy = driver
            let shown = copy.stir(at: t + Double(k) * AgentCursorTailDriver.batchStep, scale: 1.3) { _ in }
            #expect(shown == paths[k], "keyframe \(k)")
        }
    }

    /// Turning animation off settles the tail: back on, it starts from rest, with no old pose or
    /// spin carried over.
    @Test func turningAnimationOffSettlesTheTail() {
        var tail = AgentCursorTail(session: "settle-off", animates: true)
        Self.run(&tail, Self.glide(from: .zero, to: CGPoint(x: 900, y: 0)))
        tail.click()
        Self.run(&tail, Self.hold(CGPoint(x: 900, y: 0), seconds: 0.05))
        #expect(zip(tail.angles, AgentCursorTail.rest.absolute).contains { abs($0 - $1) > 0.2 }, "mid-swing")
        tail.animates = false
        tail.animates = true
        // One tiny step from far away: no jump (the pointer was forgotten) and no stored spin.
        tail.step(dt: 1 / Self.fps, pointer: CGPoint(x: -4000, y: 4000))
        let moved = zip(tail.angles, AgentCursorTail.rest.absolute).map { abs($0 - $1) }.max() ?? 1
        #expect(moved < 0.01, "re-enabled \(moved) rad from rest")
    }

    /// The real overlay on a test screen (no display needed): the tail's link and batch timer
    /// stop on hide, a batch ending with Reduce Motion turned on (and no step since) stops the
    /// tail, and the link runs again on the next step.
    @Test func theOverlaysTailClockFollowsShowMotionAndHide() {
        var reduce = false
        let screen = AgentCursorScreen(frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        let overlay = AgentCursorOverlay(reduceMotion: { reduce }, screens: { [screen] })
        overlay.show(AgentCursorEvent(kind: .move, session: "a", label: "Claude", at: CGPoint(x: 200, y: 200)))
        guard let probe = overlay.tailProbe(session: "a") else {
            Issue.record("no cursor")
            return
        }
        #expect(probe.running)
        // Calm frames from a test clock until the overlay plays ahead and sleeps.
        var t = CACurrentMediaTime()
        for _ in 0..<Int(5 * Self.fps) where !probe.batching {
            t += 1 / Self.fps
            probe.frame(at: t)
        }
        #expect(probe.batching && probe.timerRunning, "playing ahead with the link asleep")
        // Reduce Motion turns on with no step: when the batch ends, the tail stops.
        reduce = true
        probe.endBatch()
        #expect(!probe.running && !probe.timerRunning, "Reduce Motion stopped the tail")
        // The motion check comes first: a batch-end tick that finds no batch running (the tail
        // following at full rate) also stops the tail when motion is off.
        reduce = false
        overlay.show(AgentCursorEvent(kind: .click, session: "a", label: "Claude", at: CGPoint(x: 200, y: 200)))
        #expect(probe.running && !probe.batching)
        reduce = true
        probe.endBatch()
        #expect(!probe.running, "a tick with no batch running still re-checks motion")
        // Back on with the next step; then hide stops the link and the timer.
        reduce = false
        // (A click in place: a glide's animation would only end as real time passes.)
        overlay.show(AgentCursorEvent(kind: .click, session: "a", label: "Claude", at: CGPoint(x: 200, y: 200)))
        #expect(probe.running)
        for _ in 0..<Int(5 * Self.fps) where !probe.batching {
            t += 1 / Self.fps
            probe.frame(at: t)
        }
        #expect(probe.timerRunning)
        overlay.show(AgentCursorEvent(kind: .hide, session: "a", label: "Claude"))
        #expect(overlay.tailProbe(session: "a") == nil)
        #expect(!probe.running && !probe.timerRunning, "hidden: no link, no timer")
        overlay.hideAll()
    }

    @Test func thePointersTipNeverMovesWhileTheTailLives() throws {
        // A cursor that clicks, types and presses keys in place: every frame draws the pointer's tip
        // on the same pixels, whatever the tail does.
        var tips: [[UInt8]] = []
        var tails: [[UInt8]] = []
        let point = CGPoint(x: 100, y: 70)
        AgentCursorOverlay.renderFrames([Scripted(session: "tip", label: "Claude Code", start: point,
                                                  steps: [Self.at(0.3, .click), Self.at(0.8, .click), Self.at(1.2, .typing("hello")),
                                                          Self.at(2.0, .keys("cmd+s"))])],
                                        size: CGSize(width: 260, height: 180), scale: 2, fps: 30, seconds: 3.5) { _, image in
            tips.append(Self.region(image, CGRect(x: point.x - 1, y: point.y - 1, width: 7, height: 12)))
            tails.append(Self.region(image, CGRect(x: point.x + 8, y: point.y + 20, width: 28, height: 26)))
        }
        #expect(tips.count == 105)
        #expect(Set(tips).count == 1, "the tip's pixels changed: \(Set(tips).count) versions")
        #expect(Set(tails).count > 60, "the tail barely moved: \(Set(tails).count) distinct frames")
    }

    // MARK: Review frames

    typealias Scripted = AgentCursorOverlay.ScriptedCursor

    static func at(_ time: Double, _ step: Scripted.Step) -> (time: Double, step: Scripted.Step) { (time, step) }

    /// The states the review videos show. Desktop points, top-left origin.
    static var scenes: [(name: String, cursors: [Scripted], seconds: Double, animated: Bool)] {
        let s = "tail-1", label = "Claude Code"
        var zigzag: [(time: Double, step: Scripted.Step)] = []
        for i in 0..<8 {
            zigzag.append(at(0.4 + Double(i) * 0.42, .move(CGPoint(x: i % 2 == 0 ? 520 : 70, y: 60 + Double(i) * 26))))
        }
        var typing: [(time: Double, step: Scripted.Step)] = []
        for i in 0..<10 {
            typing.append(at(0.4 + Double(i) * 0.22, .typing(String("Ada Lovelace".prefix(i + 2)))))
        }
        typing.append(at(3.5, .keys("Return")))
        return [
            ("01-idle-10s", [Scripted(session: s, label: label, start: CGPoint(x: 200, y: 120), steps: [])], 10, true),
            ("02-long-move-stop", [Scripted(session: s, label: label, start: CGPoint(x: 60, y: 60),
                                            steps: [at(0.5, .move(CGPoint(x: 520, y: 200))), at(2.6, .move(CGPoint(x: 90, y: 230)))])], 5, true),
            ("03-zigzag", [Scripted(session: s, label: label, start: CGPoint(x: 60, y: 50), steps: zigzag)], 5.5, true),
            ("04-click-double-click", [Scripted(session: s, label: label, start: CGPoint(x: 250, y: 130),
                                                steps: [at(0.5, .click), at(1.8, .click), at(1.89, .click),
                                                        at(3.2, .move(CGPoint(x: 380, y: 170))), at(3.9, .click)])], 5.5, true),
            ("05-typing", [Scripted(session: s, label: label, start: CGPoint(x: 220, y: 120), steps: typing)], 5.5, true),
            ("06-drag", [Scripted(session: s, label: label, start: CGPoint(x: 100, y: 80),
                                  steps: [at(0.5, .drag(to: CGPoint(x: 440, y: 220))), at(2.2, .drag(to: CGPoint(x: 140, y: 120)))])], 4.5, true),
            ("07-paused-droop", [Scripted(session: s, label: label, start: CGPoint(x: 230, y: 110),
                                          steps: [at(0.8, .paused), at(4.0, .resume)])], 6, true),
            ("08-reduce-motion", [Scripted(session: s, label: label, start: CGPoint(x: 60, y: 60),
                                           steps: [at(0.5, .move(CGPoint(x: 420, y: 160))), at(1.5, .click), at(2.2, .typing("Ada"))])], 4, false),
            ("09-three-cursors", [
                Scripted(session: "claude-a", label: "Claude Code", start: CGPoint(x: 90, y: 60),
                         steps: [at(1.0, .move(CGPoint(x: 160, y: 90))), at(3.0, .click)]),
                Scripted(session: "codex-b", label: "Codex", start: CGPoint(x: 290, y: 70), steps: [at(2.0, .typing("hello"))]),
                Scripted(session: "claude-c", label: "Claude Code (2)", start: CGPoint(x: 190, y: 190),
                         steps: [at(4.0, .move(CGPoint(x: 420, y: 200)))]),
            ], 8, true),
        ]
    }

    @Test func writeFrameSequences() throws {
        guard let root = ProcessInfo.processInfo.environment["CMUX_CURSOR_TAIL_FRAMES_DIR"] else { return }
        let size = CGSize(width: 600, height: 300)
        for (backdropName, color) in [("light", NSColor(white: 0.94, alpha: 1)), ("dark", NSColor(white: 0.13, alpha: 1))] {
            for scene in Self.scenes {
                if backdropName == "dark", !["01-idle-10s", "02-long-move-stop", "09-three-cursors"].contains(scene.name) { continue }
                let dir = URL(fileURLWithPath: root).appendingPathComponent("\(scene.name)-\(backdropName)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var written = 0
                var failed = false
                AgentCursorOverlay.renderFrames(scene.cursors, size: size, scale: 2, fps: 60, seconds: scene.seconds,
                                                animated: scene.animated,
                                                backdrop: [(CGRect(origin: .zero, size: size), color)]) { i, image in
                    let url = dir.appendingPathComponent(String(format: "%05d.png", i))
                    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                        failed = true
                        return
                    }
                    CGImageDestinationAddImage(dest, image, nil)
                    if CGImageDestinationFinalize(dest) { written += 1 } else { failed = true }
                }
                #expect(!failed)
                #expect(written == Int((scene.seconds * 60).rounded()))
            }
        }
    }

    // MARK: Pixels

    /// The RGBA bytes of `rect` (points, top-left origin) in a 2x image.
    static func region(_ image: CGImage, _ rect: CGRect) -> [UInt8] {
        let px = AgentCursorRenderTests.pixels(image)
        let w = image.width
        var out: [UInt8] = []
        for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
            for x in Int(rect.minX * 2)..<Int(rect.maxX * 2) {
                let i = (y * w + x) * 4
                out.append(contentsOf: px[i..<(i + 4)])
            }
        }
        return out
    }
}
