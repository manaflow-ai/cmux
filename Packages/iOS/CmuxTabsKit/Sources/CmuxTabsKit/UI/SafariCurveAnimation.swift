#if os(iOS)
import SwiftUI

/// Replays a `SafariCurve` as a SwiftUI animation (the property follows
/// Safari's own per-frame progress instead of a fitted spring).
struct SafariCurveAnimation: CustomAnimation {
    let curve: SafariCurve
    /// Seconds the curve is advanced by, for a motion whose trigger reaches
    /// us later than Safari's (the slow release: one frame, measured).
    var lead: Double = 0

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time + lead < curve.duration else { return nil }
        return value.scaled(by: curve.value(at: time + lead))
    }
}

extension Animation {
    static func safari(_ curve: SafariCurve, lead: Double = 0) -> Animation {
        Animation(SafariCurveAnimation(curve: curve, lead: lead))
    }
}
#endif
