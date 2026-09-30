public import QuartzCore

extension Motion {
    /// Scale a floating panel opens from (Linear's command menu, Spotlight):
    /// with an `appear` spring and a `fadeIn`, about the panel's center.
    public static let panelOpenScale: CGFloat = 0.97
    /// Scale a floating panel closes to, with `fadeOut`: a slight shrink.
    public static let panelCloseScale: CGFloat = 0.98

    /// A uniform scale about `pivot` (in `layer`'s bounds coordinates) for
    /// the layer's `transform` or `sublayerTransform`. Core Animation
    /// applies both about the layer's anchor point, and AppKit gives a
    /// view's backing layer an anchor point of (0, 0), so a scale without
    /// this pivots on the bottom-left corner and grows in from the left.
    public static func scale(_ scale: CGFloat, about pivot: CGPoint, in layer: CALayer) -> CATransform3D {
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let dx = pivot.x - anchor.x
        let dy = pivot.y - anchor.y
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }
}
