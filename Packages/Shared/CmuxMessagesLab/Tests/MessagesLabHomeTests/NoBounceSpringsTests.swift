import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// NO BOUNCE (Lawrence 2026-11-10: no bounce in any motion of the app). No spring of this module
/// passes its target: every springs.json element through the model code the app animates with
/// (`SpringElement.value`, and `TravelLaw.apply` at the ends and the middle of its range), the tapback
/// pop springs through `Spring.progress` (the code their keyframes are sampled with), and the raw
/// `CASpringAnimation`s of the send button and the swipe reply through their own mass, stiffness,
/// damping and initial velocity, solved in closed form here. Each timing curve is also sampled with
/// its raw control points, as Core Animation gets them. Each spring is sampled every millisecond for
/// 4 s (4001 samples; the longest spring here settles in under 1 s) and fails when a sample passes
/// the end of the travel, or goes back past its start, by more than 1e-6 of the travel. A pulse
/// (an element that leaves a value and returns to it) fails when it passes that value to the other
/// side by more than 1e-6 of its largest excursion.
///
/// No animation of this module is built with an initial velocity today (springs.json has no
/// `initialVelocity`; a retarget starts from the presented value at rest). Each check uses the
/// spring's own initial velocity, so a later one that carries a spring past its target fails here.
@MainActor @Suite(.serialized) struct NoBounceSpringsTests {
    /// springs.json comes from the package, as `HomeMarkdownPolicy.install()` sets it for a pane.
    init() { HomeMarkdownPolicy.installSprings() }

    /// Seconds after the event: 0 to 4 s, one sample per millisecond.
    static let sampleTimes: [Double] = (0...4000).map { Double($0) / 1000 }
    /// A sample may be outside the travel by this share of it (the rounding of the closed form).
    static let tolerance = 1e-6

    /// How far a move from 0 to 1 is outside its travel: past the end, or back past the start.
    static func outside(_ progress: Double) -> Double { max(progress - 1, -progress) }

    /// The worst sample of `element`: how far it is outside its travel (a share of the travel) and when.
    /// A pulse: how far it is on the other side of its rest value (a share of its largest excursion).
    static func worst(_ element: SpringElement) -> (share: Double, time: Double) {
        var found = (share: 0.0, time: 0.0)
        if element.isPulse {
            let values = sampleTimes.map { element.value($0, from: 0, to: 0) }
            var peak = 0.0
            for v in values where abs(v) > abs(peak) { peak = v }
            guard abs(peak) > 0 else { return found }
            for (t, v) in zip(sampleTimes, values) where -(v / peak) > found.share { found = (share: -(v / peak), time: t) }
            return found
        }
        for t in sampleTimes {
            let out = outside(element.value(t, from: 0, to: 1))
            if out > found.share { found = (share: out, time: t) }
        }
        return found
    }

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

    /// The worst sample of a raw spring animation, from its own mass, stiffness, damping and initial velocity.
    static func worst(_ a: CASpringAnimation) -> (share: Double, time: Double) {
        var found = (share: 0.0, time: 0.0)
        for t in sampleTimes {
            let out = outside(springProgress(t, mass: Double(a.mass), stiffness: Double(a.stiffness), damping: Double(a.damping),
                                             velocity: Double(a.initialVelocity)))
            if out > found.share { found = (share: out, time: t) }
        }
        return found
    }

    /// The damping ratio of a raw spring animation (1: critical).
    static func dampingRatio(_ a: CASpringAnimation) -> Double {
        Double(a.damping) / (2 * (Double(a.stiffness) * Double(a.mass)).squareRoot())
    }

    /// A share as a percentage with four decimals.
    static func percent(_ share: Double) -> Double { (share * 1_000_000).rounded() / 10_000 }

    @Test func everySpringsJSONElementStaysInsideItsTravel() {
        let elements = Springs.all
        #expect(elements.count >= 50, "springs.json did not load: \(elements.count) elements")
        for name in elements.keys.sorted() {
            guard let element = elements[name] else { continue }
            var variants: [(label: String, element: SpringElement)] = [(name, element)]
            if let law = Springs.travelLaws[name] {
                for travel in [law.minPt, (law.minPt + law.maxPt) / 2, law.maxPt] {
                    variants.append(("\(name) on its travel law at \(travel) pt", law.apply(element, travel: travel)))
                }
            }
            for variant in variants {
                let w = Self.worst(variant.element)
                let kind = variant.element.isPulse ? "pulse passes its rest value by" : "passes its target by"
                #expect(w.share <= Self.tolerance,
                        "springs.json \(variant.label) \(kind) \(Self.percent(w.share)) % at \(w.time) s")
            }
        }
    }

    /// A cubic timing curve with its raw control points, as `CAMediaTimingFunction(controlPoints:)`
    /// gets them from `Curve.timingFunction`. `Curve.solve` clamps the points to 0...1 first, so the
    /// model alone does not show a point outside that range.
    static func rawCurveProgress(_ u: Double, _ c: Curve) -> Double {
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * c.x1 + 3 * (1 - s) * s * s * c.x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * c.y1 + 3 * (1 - s) * s * s * c.y2 + s * s * s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let m = (lo + hi) / 2
            if bx(m) < u { lo = m } else { hi = m }
        }
        return by((lo + hi) / 2)
    }

    @Test func everyTimingCurveStaysInsideItsTravelWithItsRawControlPoints() {
        var elements = Springs.all
        elements.updateValue(SequenceScroller.slideStop, forKey: SequenceScroller.slideStop.name)
        for name in elements.keys.sorted() {
            guard let element = elements[name] else { continue }
            for (i, component) in element.components.enumerated() {
                guard let curve = component.curve else { continue }
                var found = (share: 0.0, at: 0.0)
                for k in 0...2000 {
                    let u = Double(k) / 2000
                    let out = Self.outside(Self.rawCurveProgress(u, curve))
                    if out > found.share { found = (share: out, at: u) }
                }
                #expect(found.share <= Self.tolerance,
                        "\(name) component \(i): the curve (\(curve.x1), \(curve.y1), \(curve.x2), \(curve.y2)) is outside its travel by \(Self.percent(found.share)) % at \(found.at) of its duration")
            }
        }
    }

    @Test func theElementsBuiltInCodeStayInsideTheirTravel() {
        let elements = [Springs.typingPop, Springs.typingFade, Springs.receiptOldOut, Springs.receiptNewIn, Springs.typingOut,
                        Springs.receivedFade, Springs.receiptIn, Springs.receiptPop, Springs.ghostOut, Springs.landFade,
                        Springs.connectorDraw, Springs.textUnblur, Springs.fieldGrow, Springs.scrollToBottom,
                        SequenceScroller.slideStop, Springs.element("no.such.element")]
        for element in elements {
            let w = Self.worst(element)
            #expect(w.share <= Self.tolerance, "\(element.name) passes its target by \(Self.percent(w.share)) % at \(w.time) s")
        }
    }

    @Test func theTapbackPopSpringsStayInsideTheirTravel() {
        let springs = [(name: "RowCell.popDisc", spring: RowCell.popDisc.spring), (name: "RowCell.popGlyph", spring: RowCell.popGlyph.spring)]
        for s in springs {
            var found = (share: 0.0, time: 0.0)
            for t in Self.sampleTimes {
                let out = Self.outside(s.spring.progress(t))
                if out > found.share { found = (share: out, time: t) }
            }
            #expect(found.share <= Self.tolerance,
                    "\(s.name) (duration \(s.spring.duration) s, bounce \(s.spring.bounce)) passes its target by \(Self.percent(found.share)) % at \(found.time) s")
        }
    }

    @Test func theSendButtonSpringStaysInsideItsTravel() {
        let a = ComposeSendButton.showSpring()
        let w = Self.worst(a)
        #expect(w.share <= Self.tolerance,
                "ComposeSendButton.showSpring (stiffness \(a.stiffness), damping \(a.damping), damping ratio \(Self.dampingRatio(a))) passes its target by \(Self.percent(w.share)) % at \(w.time) s")
    }

    @Test func theSwipeReplyReturnSpringStaysInsideItsTravel() {
        let a = SwipeReply.returnSpring()
        let w = Self.worst(a)
        #expect(w.share <= Self.tolerance,
                "SwipeReply.returnSpring (stiffness \(a.stiffness), damping \(a.damping), damping ratio \(Self.dampingRatio(a))) passes its target by \(Self.percent(w.share)) % at \(w.time) s")
    }
}
