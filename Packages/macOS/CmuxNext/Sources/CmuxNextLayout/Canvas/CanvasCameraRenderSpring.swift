import CmuxNextDesign
import CoreGraphics
import QuartzCore

/// The canvas camera's springs on the render server, as values (chrome-parity R2).
///
/// The view's bounds rest at the target camera from the change's turn. Two channels on the screen
/// layer show the move there, and they do not interact, so springs added by later changes stack in any
/// order:
/// - the center: additive springs on `bounds.origin.x` and `.y`, which shift every sublayer (layer units);
/// - the zoom: additive `sublayerTransform` springs, each a scale about the viewport center
///   (``CanvasZoomTransform``). Scales about one point commute, and the viewport center does not
///   move under them.
///
/// The shown center is the rest center plus the summed bounds offsets over ``axes``; the shown zoom is the
/// rest zoom times every scale. With no carried velocity this is exactly the main thread's path
/// (`CanvasCameraMotion.advance`: center and zoom on one spring each). A retarget adds springs per
/// channel from what shows, with the speed the running springs do not carry, so value and velocity stay
/// continuous, also when the main thread hands over a moving camera (a zoom spring starts at a progress
/// velocity: Core Animation's normalized `initialVelocity`, which a transform takes as a scalar does).
/// Chrome keeps each compositor animation's curve and start on the main thread the same way
/// (`cc/animation/keyframe_model.h`) and retargets from the current value and velocity
/// (`ScrollOffsetAnimationCurve::UpdateTarget`).
nonisolated struct CanvasCameraRenderSpring: Hashable, Sendable {
    /// A scale by `ratio` about the viewport center that springs to 1 from `begin`. Its displacement from 1,
    /// as a share of `ratio - 1`, starts at 1 and moves at `velocity` per second; the layer's spring starts at
    /// the progress velocity `-velocity`.
    nonisolated struct Zoom: Hashable, Sendable {
        var ratio: Double
        var velocity: Double
        var begin: Double
        var parameters: SpringParameters

        /// The scale and its rate at `time`.
        func scale(at time: Double) -> (scale: Double, rate: Double) {
            let state = SpringValue.solve(displacement: 1, velocity: velocity, time: max(0, time - begin), parameters: parameters)
            return (1 + (ratio - 1) * state.displacement, (ratio - 1) * state.velocity)
        }

        /// It adds nothing at `time` any more.
        func rests(at time: Double) -> Bool {
            time - begin >= parameters.settlingTime(within: 0.0001 / (1 + abs(velocity) / parameters.omega))
        }
    }

    /// A bounds-origin offset (layer units) that springs to 0 from `begin`, starting at `velocity`.
    nonisolated struct Center: Hashable, Sendable {
        var offset: CGPoint
        var velocity: CGPoint
        var begin: Double
        var parameters: SpringParameters
    }

    /// What one retarget adds: the zoom springs (none, one, or a carrier and a still one) and the center
    /// spring's start.
    nonisolated struct Added: Hashable, Sendable {
        var zooms: [Zoom]
        var centerOffset: CGPoint
        var centerVelocity: CGPoint
    }

    /// The camera the springs land on.
    private(set) var rest: CanvasCamera
    /// The screen layer's units per canvas point at ``rest``, per axis.
    private(set) var axes: RenderLayerAxes
    private(set) var zooms: [Zoom] = []
    private(set) var centers: [Center] = []

    init(rest: CanvasCamera, axes: RenderLayerAxes) {
        self.rest = rest
        self.axes = axes
    }

    /// The camera shown at `time` and its speed.
    func shown(at time: Double) -> CanvasCameraState {
        let zoom = zoomFactor(at: time), center = centerOffset(at: time)
        return CanvasCameraState(center: CGPoint(x: rest.center.x + Self.canvas(center.offset.x, axes.x),
                                                 y: rest.center.y + Self.canvas(center.offset.y, axes.y)),
                                 zoom: rest.zoom * zoom.factor,
                                 centerRate: CGPoint(x: Self.canvas(center.velocity.x, axes.x), y: Self.canvas(center.velocity.y, axes.y)),
                                 zoomRate: rest.zoom * zoom.rate)
    }

    /// Lands on `rest` (with `axes`) from `shown` at `time`: the springs still running carry on, and the
    /// added springs make up the rest of the difference and of the speed. Returns what to add.
    mutating func retarget(to rest: CanvasCamera, axes: RenderLayerAxes, shown: CanvasCameraState, at time: Double,
                           parameters: SpringParameters) -> Added {
        // Springs at rest by now add nothing: a record holds only the ones that still move.
        zooms.removeAll { $0.rests(at: time) }
        centers.removeAll { time - $0.begin >= $0.parameters.settlingTime(within: 0.0001) }
        let running = zoomFactor(at: time), carried = centerOffset(at: time)
        let scales = running.factor > 0 && rest.zoom > 0
        let ratio = scales ? shown.zoom / (rest.zoom * running.factor) : 1
        // The zoom's speed the running springs do not carry, as the added springs' scale rate: the shown rate
        // is rest.zoom * (running.rate * ratio + running.factor * excess) at `time`.
        let excess = scales ? (shown.zoomRate / rest.zoom - running.rate * ratio) / running.factor : 0
        let added = Added(zooms: Self.zooms(ratio: ratio, rate: excess, at: time, parameters: parameters),
                          centerOffset: CGPoint(x: axes.x * (shown.center.x - rest.center.x) - carried.offset.x,
                                                y: axes.y * (shown.center.y - rest.center.y) - carried.offset.y),
                          centerVelocity: CGPoint(x: axes.x * shown.centerRate.x - carried.velocity.x,
                                                  y: axes.y * shown.centerRate.y - carried.velocity.y))
        self.rest = rest
        self.axes = axes
        zooms += added.zooms
        if added.centerOffset != .zero || added.centerVelocity != .zero {
            centers.append(Center(offset: added.centerOffset, velocity: added.centerVelocity, begin: time, parameters: parameters))
        }
        return added
    }

    /// The zoom springs that scale by `ratio` at `time` and spring to 1, their product starting at the scale
    /// rate `rate` (per second): one spring; or, when `ratio` is too close to 1 to carry the rate (a zoom
    /// moving through its target), a carrier with the rate and a still spring that makes up the ratio, as
    /// `RenderSpring.parts` splits a scalar. Products of scales about one point stack in any order.
    static func zooms(ratio: Double, rate: Double, at time: Double, parameters: SpringParameters) -> [Zoom] {
        let rate = abs(rate) < 1e-9 ? 0 : rate
        let single: [Zoom] = ratio == 1 ? [] : [Zoom(ratio: ratio, velocity: rate == 0 ? 0 : rate / (ratio - 1), begin: time, parameters: parameters)]
        guard rate != 0, abs(ratio - 1) < abs(rate) / parameters.omega * 1e-3 else { return single }
        let carrier = ratio + rate / parameters.omega, still = ratio / carrier
        // A rate that would scale through zero within one response keeps the one spring (or, at ratio 1, none).
        guard carrier > 0, carrier != 1 else { return single }
        // The product's rate at `time` is the carrier's: still * (carrier - 1) * velocity = rate.
        let lead = Zoom(ratio: carrier, velocity: rate / (still * (carrier - 1)), begin: time, parameters: parameters)
        return still == 1 ? [lead] : [lead, Zoom(ratio: still, velocity: 0, begin: time, parameters: parameters)]
    }

    /// The product of every zoom spring's scale at `time`, and its rate.
    private func zoomFactor(at time: Double) -> (factor: Double, rate: Double) {
        var factor = 1.0, rate = 0.0
        for zoom in zooms {
            let (scale, scaleRate) = zoom.scale(at: time)
            rate = rate * scale + factor * scaleRate
            factor *= scale
        }
        return (factor, rate)
    }

    /// The sum of every center spring's offset at `time` (layer units), and its rate.
    private func centerOffset(at time: Double) -> (offset: CGPoint, velocity: CGPoint) {
        var offset = CGPoint.zero, velocity = CGPoint.zero
        for center in centers {
            let elapsed = max(0, time - center.begin)
            let x = SpringValue.solve(displacement: Double(center.offset.x), velocity: Double(center.velocity.x), time: elapsed,
                                      parameters: center.parameters)
            let y = SpringValue.solve(displacement: Double(center.offset.y), velocity: Double(center.velocity.y), time: elapsed,
                                      parameters: center.parameters)
            offset.x += CGFloat(x.displacement)
            offset.y += CGFloat(y.displacement)
            velocity.x += CGFloat(x.velocity)
            velocity.y += CGFloat(y.velocity)
        }
        return (offset, velocity)
    }

    /// A layer-unit length in canvas points along an axis of `scale` layer units per canvas point.
    private static func canvas(_ length: CGFloat, _ scale: CGFloat) -> CGFloat {
        scale == 0 ? 0 : length / scale
    }
}

/// A uniform scale of a layer's sublayers by `scale` about `pivot`, as its `sublayerTransform`: Core
/// Animation applies the transform about the layer's anchor point, and `pivot` is measured from there
/// (layer units). The canvas camera springs its zoom with it (``CanvasCameraRenderSpring``).
///
/// An additive transform animation concatenates with the layer's transform, so this value's zero is the
/// identity, and its difference from a target is a ratio, not a subtraction.
nonisolated struct CanvasZoomTransform: RenderSpringValue, Hashable {
    var scale: CGFloat
    var pivot: CGPoint
    /// The farthest a point of the layer's bounds is from the pivot: how far a ratio moves what shows.
    var reach: CGFloat

    init(scale: CGFloat, pivot: CGPoint, reach: CGFloat) {
        self.scale = scale
        self.pivot = pivot
        self.reach = reach
    }

    /// A uniform scale with a translation in x and y and nothing else; nil for any other value.
    init?(layerValue: Any?) {
        guard let value = layerValue as? NSValue else { return nil }
        let m = value.caTransform3DValue
        guard m.m11 == m.m22, m.m33 == 1, m.m44 == 1, m.m12 == 0, m.m13 == 0, m.m14 == 0, m.m21 == 0, m.m23 == 0, m.m24 == 0,
              m.m31 == 0, m.m32 == 0, m.m34 == 0, m.m43 == 0, m.m11 != 0 else { return nil }
        scale = m.m11
        pivot = scale == 1 ? .zero : CGPoint(x: m.m41 / (1 - scale), y: m.m42 / (1 - scale))
        reach = 0
    }

    /// The value as a `sublayerTransform`.
    var transform: CATransform3D {
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = (1 - scale) * pivot.x
        transform.m42 = (1 - scale) * pivot.y
        return transform
    }

    var layerValue: Any { NSValue(caTransform3D: transform) }

    static var springZero: CanvasZoomTransform { CanvasZoomTransform(scale: 1, pivot: .zero, reach: 0) }

    /// The scale that, after `target`, shows this one: a ratio about the same pivot.
    func springDelta(to target: CanvasZoomTransform) -> CanvasZoomTransform {
        CanvasZoomTransform(scale: target.scale == 0 ? scale : scale / target.scale, pivot: pivot, reach: reach)
    }

    var springExtent: CGFloat { abs(scale - 1) * reach }

    var springScalar: CGFloat? { nil }
}

extension RenderSpringKey where Value == CanvasZoomTransform {
    /// A layer's `sublayerTransform` as a canvas zoom (nil when it holds any other transform).
    static var canvasZoom: Self {
        Self("sublayerTransform", read: { CanvasZoomTransform(layerValue: NSValue(caTransform3D: $0.sublayerTransform)) },
             write: { $0.sublayerTransform = $1.transform })
    }
}
