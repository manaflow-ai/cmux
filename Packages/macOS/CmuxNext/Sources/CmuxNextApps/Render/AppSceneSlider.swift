import Foundation

/// The `Slider` node's value math: `min...max`, snapped to `step` (a hundredth of the range when
/// absent, so a drag sends at most about a hundred `change {value}` events). The AppKit slider
/// (`AppSceneSliderNSView`) draws the node; this is what it sends.
enum AppSceneSlider {
    /// `min...max`; an empty or reversed range is the default 0...1.
    static func range(_ node: AppSceneNode) -> ClosedRange<Double> {
        let low = node.number("min") ?? 0, high = node.number("max") ?? 1
        return low.isFinite && high.isFinite && low < high ? low...high : 0...1
    }

    static func step(_ node: AppSceneNode, _ range: ClosedRange<Double>) -> Double {
        if let step = node.number("step"), step.isFinite, step > 0 { return step }
        return (range.upperBound - range.lowerBound) / 100
    }

    /// `value` clamped to `range` and snapped to the nearest step from its lower bound.
    static func snap(_ value: Double, _ range: ClosedRange<Double>, _ step: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let snapped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        // Round to the step's own decimals, so a 0.1 step sends 0.3, not 0.30000000000000004.
        let decimals = Double(min(max(Int((-log10(step)).rounded(.up)) + 6, 0), 12))
        let scale = pow(10, decimals)
        return min(max((snapped * scale).rounded() / scale, range.lowerBound), range.upperBound)
    }
}
