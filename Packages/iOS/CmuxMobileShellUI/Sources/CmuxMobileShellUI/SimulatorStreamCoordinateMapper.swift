import CoreGraphics

struct SimulatorStreamCoordinateMapper: Equatable {
    let viewSize: CGSize
    let imageSize: CGSize

    var fittedImageRect: CGRect {
        guard viewSize.width > 0,
              viewSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// The result is always clamped to `0...1`; `allowsOutsideImage` only
    /// controls whether a point outside the letterboxed image is rejected
    /// (`nil`) instead of clamped to the nearest edge.
    func normalizedPoint(from point: CGPoint, allowsOutsideImage: Bool = true) -> CGPoint? {
        let rect = fittedImageRect
        guard !rect.isEmpty else { return nil }
        if !allowsOutsideImage, !rect.contains(point) { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}
