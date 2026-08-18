#if canImport(UIKit)
import QuartzCore

/// Transform-independent geometry for the live terminal renderer layer.
///
/// Native scrolling owns the layer transform. Layout therefore cannot use
/// `frame`, whose value includes that transform, without interpreting every
/// sub-row scroll translation as a layout change and cancelling it.
@MainActor
struct TerminalRenderLayerGeometry: Equatable {
    let bounds: CGRect
    let position: CGPoint

    init(renderRect: CGRect) {
        bounds = CGRect(origin: .zero, size: renderRect.size)
        position = CGPoint(x: renderRect.midX, y: renderRect.midY)
    }

    func matches(_ layer: CALayer) -> Bool {
        layer.bounds == bounds && layer.position == position
    }

    func apply(to layer: CALayer) {
        layer.bounds = bounds
        layer.position = position
    }
}
#endif
