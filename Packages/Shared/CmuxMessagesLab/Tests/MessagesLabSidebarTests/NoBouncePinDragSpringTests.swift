import AppKit
import Foundation
import Testing
@testable import MessagesLabSidebar

/// NO BOUNCE (Lawrence 2026-11-10: no bounce in any motion of the app). No spring of the sidebar
/// passes its target: the pin drag's spring (the lift, the drop and every row or tile that makes
/// room) and the typing bubble's pop, each from the animation the code adds (its own mass,
/// stiffness, damping and initial velocity), solved in closed form here. Sampled every millisecond
/// for 4 s (4001 samples); a sample past the end of the travel, or back past its start, by more
/// than 1e-6 of the travel fails.
///
/// No sidebar animation is built with an initial velocity today (a retarget starts from the
/// presented value at rest). Each check uses the animation's own initial velocity, so a later one
/// that carries a spring past its target fails here.
@MainActor
@Suite(.serialized)
struct NoBouncePinDragSpringTests {
    /// Seconds after the start: 0 to 4 s, one sample per millisecond.
    static let sampleTimes: [Double] = (0...4000).map { Double($0) / 1000 }
    /// A sample may be outside the travel by this share of it (the rounding of the closed form).
    static let tolerance = 1e-6

    /// A mass-spring-damper from 0 to 1 in closed form, as Core Animation runs a `CASpringAnimation`
    /// (`velocity`: travels per second, positive toward the target).
    static func springProgress(_ t: Double, mass m: Double, stiffness k: Double, damping c: Double, velocity v0: Double) -> Double {
        guard t > 0, m > 0, k > 0 else { return 0 }
        let w0 = (k / m).squareRoot()
        let zeta = c / (2 * (k * m).squareRoot())
        let x0 = -1.0
        if zeta < 1 - 1e-9 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            return 1 + exp(-zeta * w0 * t) * (x0 * cos(wd * t) + (v0 + zeta * w0 * x0) / wd * sin(wd * t))
        }
        if zeta <= 1 + 1e-9 {
            return 1 + exp(-w0 * t) * (x0 + (v0 + w0 * x0) * t)
        }
        let s = (zeta * zeta - 1).squareRoot()
        let r1 = -w0 * (zeta - s), r2 = -w0 * (zeta + s)
        let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
        return 1 + c1 * exp(r1 * t) + c2 * exp(r2 * t)
    }

    /// The worst sample of a spring animation: how far it is outside its travel (a share of the travel) and when.
    static func worst(_ a: CASpringAnimation) -> (share: Double, time: Double) {
        var found = (share: 0.0, time: 0.0)
        for t in sampleTimes {
            let p = springProgress(t, mass: Double(a.mass), stiffness: Double(a.stiffness), damping: Double(a.damping),
                                   velocity: Double(a.initialVelocity))
            let out = max(p - 1, -p)
            if out > found.share { found = (share: out, time: t) }
        }
        return found
    }

    /// The damping ratio of a spring animation (1: critical).
    static func dampingRatio(_ a: CASpringAnimation) -> Double {
        Double(a.damping) / (2 * (Double(a.stiffness) * Double(a.mass)).squareRoot())
    }

    /// A share as a percentage with four decimals.
    static func percent(_ share: Double) -> Double { (share * 1_000_000).rounded() / 10_000 }

    @Test func thePinDragSpringStaysInsideItsTravel() {
        for keyPath in ["transform.scale", "position", "transform.translation.y"] {
            let a = SidebarController.pinDragSpring(keyPath)
            let w = Self.worst(a)
            #expect(w.share <= Self.tolerance,
                    "SidebarController.pinDragSpring(\(keyPath)) (stiffness \(a.stiffness), damping \(a.damping), damping ratio \(Self.dampingRatio(a))) passes its target by \(Self.percent(w.share)) % at \(w.time) s")
        }
    }

    @Test func theTypingPopSpringStaysInsideItsTravel() throws {
        let layer = CALayer()
        SidebarMotion.typingIn(layer)
        let a = try #require(layer.animation(forKey: "typingIn.scale") as? CASpringAnimation)
        let w = Self.worst(a)
        #expect(w.share <= Self.tolerance,
                "SidebarMotion.typingIn (stiffness \(a.stiffness), damping \(a.damping), damping ratio \(Self.dampingRatio(a))) passes its target by \(Self.percent(w.share)) % at \(w.time) s")
    }
}
