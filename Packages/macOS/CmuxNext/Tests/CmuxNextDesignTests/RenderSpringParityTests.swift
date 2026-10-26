import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import QuartzCore
import Testing

/// chrome-parity DC4 (plans/cmux-next/chrome-parity/p03-rendering.md, task 020): the
/// render-server spring (`RenderSpring`, an additive `CASpringAnimation`) shows the path
/// cmux-motion's closed form (`SpringValue.solve`) computes, within 0.25 pt at 240 samples for
/// every token, read through `presentation()`; a perpendicular retarget keeps the presented
/// value and velocity continuous; and with motion off the value lands in one frame.
///
/// The layers hang under a root whose `speed` is 0, so the spring's clock is the root's
/// `timeOffset`: each sample sets it and reads the presentation layer at exactly that time.
@MainActor @Suite(.serialized) struct RenderSpringParityTests {
    static let samples = 240
    static let tolerance: CGFloat = 0.25
    static let gate = Motion.panes

    /// A layer whose spring time the test sets.
    final class Scrubber {
        let root = CALayer()
        let layer = CALayer()

        init(frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.speed = 0
            root.timeOffset = 0
            root.frame = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
            layer.frame = frame
            root.addSublayer(layer)
            CATransaction.commit()
            CATransaction.flush()
        }

        /// Moves the spring clock to `time` seconds.
        func seek(_ time: CFTimeInterval) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.timeOffset = time
            CATransaction.commit()
            CATransaction.flush()
        }

        /// The presented `keyPath` of `layer` at `time` seconds.
        func presented(_ keyPath: String, at time: CFTimeInterval, of layer: CALayer? = nil) throws -> CGFloat {
            seek(time)
            let shown = try #require((layer ?? self.layer).presentation(), "no presentation layer after a commit")
            return try #require(CGFloat(layerValue: shown.value(forKeyPath: keyPath)), "\(keyPath) is not a scalar")
        }
    }

    /// Movement animates for the panes gate on this host (Reduce Motion pinned off).
    static func withMotion<T>(_ body: () throws -> T) throws -> T {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(gate.animatesMovement, "panes movement is off in this host's settings")
        return try body()
    }

    /// The closed-form reference: `target` plus the spring's displacement `time` seconds after it
    /// started at `start` with `velocity`.
    static func reference(from start: CGFloat, to target: CGFloat, velocity: CGFloat = 0, at time: Double,
                          spring: SpringParameters) -> (value: CGFloat, velocity: CGFloat) {
        guard time > 0 else { return (start, velocity) }
        let solved = SpringValue.solve(displacement: Double(start - target), velocity: Double(velocity), time: time, parameters: spring)
        return (target + CGFloat(solved.displacement), CGFloat(solved.velocity))
    }

    @Test func everyTokenMatchesTheClosedFormWithinAQuarterPoint() throws {
        try Self.withMotion {
            for token in MotionSpring.allCases {
                let scrubber = Scrubber()
                let spring = Self.gate.spring(token)
                let start = scrubber.layer.position.x
                let target = start + 200
                Self.gate.renderSpring(token).animate(scrubber.layer, "position.x", to: target)
                #expect(scrubber.layer.position.x == target, "\(token): the model is not at rest at once")
                let end = RenderSpring.duration(extent: 200, spring: spring)
                var worst: CGFloat = 0
                for index in 1...Self.samples {
                    let time = end * Double(index) / Double(Self.samples)
                    let shown = try scrubber.presented("position.x", at: time)
                    worst = max(worst, abs(shown - Self.reference(from: start, to: target, at: time, spring: spring).value))
                }
                #expect(worst <= Self.tolerance, "\(token): presented path is \(worst) pt off cmux-motion's")
            }
        }
    }

    @Test func aReleaseVelocityStartsTheSpringWithThatVelocity() throws {
        try Self.withMotion {
            let spring = Self.gate.spring(.settle)
            // A fling whose rest is 200 pt away, and one released at its rest (the two-spring carrier).
            for (distance, velocity) in [(CGFloat(200), CGFloat(-900)), (0, 1_200)] {
                let scrubber = Scrubber()
                let start = scrubber.layer.position.x
                Self.gate.renderSpring(.settle).animate(scrubber.layer, "position.x", to: start + distance, velocity: velocity)
                let end = RenderSpring.duration(extent: abs(distance) + abs(velocity) / CGFloat(spring.omega), spring: spring)
                var worst: CGFloat = 0
                for index in 1...Self.samples {
                    let time = end * Double(index) / Double(Self.samples)
                    let shown = try scrubber.presented("position.x", at: time)
                    let expected = Self.reference(from: start, to: start + distance, velocity: velocity, at: time, spring: spring).value
                    worst = max(worst, abs(shown - expected))
                }
                #expect(worst <= Self.tolerance, "fling \(distance) pt at \(velocity) pt/s: \(worst) pt off cmux-motion's")
                let h = 1e-3
                let early = try (scrubber.presented("position.x", at: h) - scrubber.presented("position.x", at: 0)) / CGFloat(h)
                let expected = Self.reference(from: start, to: start + distance, velocity: velocity, at: h / 2, spring: spring).velocity
                #expect(abs(early - expected) <= abs(velocity) * 0.02 + 2, "starts at \(early) pt/s, released at \(velocity)")
            }
        }
    }

    @Test func aPerpendicularRetargetKeepsValueAndVelocityContinuous() throws {
        try Self.withMotion {
            let token = MotionSpring.split
            let spring = Self.gate.spring(token)
            let scrubber = Scrubber()
            let origin = scrubber.layer.position
            let first = CGPoint(x: origin.x + 200, y: origin.y)
            let second = CGPoint(x: origin.x + 200, y: origin.y + 200)
            let render = Self.gate.renderSpring(token)
            render.animate(scrubber.layer, "position", to: first)
            let retarget = 0.4 * RenderSpring.duration(extent: 200, spring: spring)
            scrubber.seek(retarget)
            render.animate(scrubber.layer, "position", to: second)

            let springs = (scrubber.layer.animationKeys() ?? []).compactMap { scrubber.layer.animation(forKey: $0) as? CASpringAnimation }
            #expect(springs.count == 2, "a retarget stacks one spring, it does not replace the running one")
            #expect(springs.allSatisfy { $0.isAdditive && $0.initialVelocity == 0 })

            /// The reference (value, velocity) of one axis: x never retargets, y starts at the retarget.
            func expected(_ keyPath: String, _ time: Double) -> (value: CGFloat, velocity: CGFloat) {
                if keyPath == "position.x" { return Self.reference(from: origin.x, to: first.x, at: time, spring: spring) }
                guard time > retarget else { return (origin.y, 0) }
                return Self.reference(from: origin.y, to: second.y, at: time - retarget, spring: spring)
            }

            let end = retarget + RenderSpring.duration(extent: 200, spring: spring)
            var worst: CGFloat = 0
            for index in 1...Self.samples {
                let time = end * Double(index) / Double(Self.samples)
                for keyPath in ["position.x", "position.y"] {
                    let shown = try scrubber.presented(keyPath, at: time)
                    worst = max(worst, abs(shown - expected(keyPath, time).value))
                }
            }
            #expect(worst <= Self.tolerance, "retargeted path is \(worst) pt off cmux-motion's")

            // Finite differences on each side of the retarget against the reference velocity there.
            let h = 1e-3
            for keyPath in ["position.x", "position.y"] {
                let at = try scrubber.presented(keyPath, at: retarget)
                let earlier = try scrubber.presented(keyPath, at: retarget - h)
                let later = try scrubber.presented(keyPath, at: retarget + h)
                let before = (at - earlier) / CGFloat(h)
                let after = (later - at) / CGFloat(h)
                let wantBefore = expected(keyPath, retarget - h / 2).velocity
                let wantAfter = expected(keyPath, retarget + h / 2).velocity
                let slack = max(abs(wantBefore), abs(wantAfter)) * 0.02 + 2
                #expect(abs(at - expected(keyPath, retarget).value) <= Self.tolerance, "\(keyPath) jumps at the retarget")
                #expect(abs(before - wantBefore) <= slack, "\(keyPath) moves at \(before) pt/s before the retarget, not \(wantBefore)")
                #expect(abs(after - wantAfter) <= slack, "\(keyPath) moves at \(after) pt/s after the retarget, not \(wantAfter)")
            }
        }
    }

    @Test func aGroupGivesEverySublayerTheHostsSpringAndBeginTime() throws {
        try Self.withMotion {
            let scrubber = Scrubber()
            let ring = CALayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = scrubber.layer.bounds.insetBy(dx: -2, dy: -2)
            scrubber.layer.addSublayer(ring)
            CATransaction.commit()
            let hostRest = CGRect(x: 0, y: 0, width: 300, height: 100)
            let ringRest = CGRect(origin: .zero, size: hostRest.size).insetBy(dx: -2, dy: -2)
            Self.gate.renderSpring(.split).animateGroup(host: scrubber.layer, to: hostRest, sublayers: [(ring, ringRest)])
            #expect(scrubber.layer.frame == hostRest && ring.frame == ringRest, "the rest frames are not the model at once")

            let added = [scrubber.layer, ring].flatMap { layer in
                (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
            }
            #expect(added.count == 4, "host and ring each spring position and bounds.size")
            #expect(Set(added.map(\.beginTime)).count == 1, "the springs start at different times")
            #expect(Set(added.map(\.stiffness)).count == 1 && Set(added.map(\.damping)).count == 1)

            let spring = Self.gate.spring(.split)
            let end = RenderSpring.duration(extent: 200, spring: spring)
            for fraction in [0.25, 0.5, 0.75] {
                let time = end * fraction
                let hostWidth = try scrubber.presented("bounds.size.width", at: time)
                let ringWidth = try scrubber.presented("bounds.size.width", at: time, of: ring)
                let want = Self.reference(from: 100, to: 300, at: time, spring: spring).value
                #expect(abs(hostWidth - want) <= Self.tolerance)
                #expect(abs(ringWidth - (hostWidth + 4)) <= Self.tolerance, "the ring's edge leaves the host's at \(fraction)")
            }
        }
    }

    /// A completion's run, set from a main-actor closure.
    final class Flag {
        var done = false
    }

    @Test func withMovementOffTheValueLandsInOneFrameAndTheCompletionRuns() throws {
        let scrubber = Scrubber()
        let render = Self.gate.renderSpring(.move)
        let start = scrubber.layer.position.x
        try Self.withMotion { render.animate(scrubber.layer, "position.x", to: start + 200) }
        #expect(!(scrubber.layer.animationKeys() ?? []).isEmpty)

        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let completed = Flag()
        render.animate(scrubber.layer, "position.x", to: start + 400) { completed.done = true }
        #expect(completed.done, "the completion waits for an animation that never runs")
        #expect(scrubber.layer.position.x == start + 400)
        #expect((scrubber.layer.animationKeys() ?? []).allSatisfy { RenderSpring.springKeyPath($0) == nil },
                "a spring left from before keeps the value from landing in one frame")
        #expect(try scrubber.presented("position.x", at: 0.05) == start + 400)
    }

    @Test(.enabled("needs a display that draws frames") { await GUIAnimationTestSupport.animatesHere() })
    func theCompletionRunsWhenTheSpringsEnd() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Self.gate.animatesMovement)
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let host = try #require(content.layer)
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        host.addSublayer(layer)
        window.orderFrontRegardless()
        let landed = Flag()
        Self.gate.renderSpring(.move).animate(layer, "position.x", to: 150, in: content) { landed.done = true }
        #expect(!landed.done, "the completion ran before the spring")
        #expect(await GUIAnimationTestSupport.settle(within: 10) { landed.done }, "the landing completion never ran")
    }

    /// The retarget path reads no CPU spring and no presentation layer: what is on screen
    /// comes from the running springs alone.
    @Test func theRetargetPathStepsNoCPUSpring() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextDesign/Motion/RenderSpring.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        for banned in [#"\bSpringValue\b"#, #"\bMotionPath\b"#, #"\bAnimatedFrame\b"#, #"presentation\(\)"#] {
            #expect(code.range(of: banned, options: .regularExpression) == nil, "RenderSpring.swift calls \(banned)")
        }
    }
}
