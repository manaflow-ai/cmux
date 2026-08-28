import CoreGraphics
import Foundation

/// Pure geometry for touch forwarding: where the aspect-fit video actually
/// sits inside the view, and how a view point maps to the normalized [0,1]
/// coordinates the simulator HID expects.
public enum SimStreamTouchMapping {
    /// The aspect-fit rect of a video with `pixelSize` inside `bounds`
    /// (mirrors AVSampleBufferDisplayLayer's `.resizeAspect`).
    public static func videoRect(pixelSize: CGSize, in bounds: CGRect) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0,
            bounds.width > 0, bounds.height > 0
        else { return .zero }
        let scale = min(
            bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(
            width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Maps a view-space point into normalized video coordinates, or nil for
    /// touches in the letterbox area outside the video.
    public static func normalizedPoint(
        _ point: CGPoint, pixelSize: CGSize, in bounds: CGRect
    ) -> CGPoint? {
        let rect = videoRect(pixelSize: pixelSize, in: bounds)
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (point.y - rect.minY) / rect.height
        )
    }

    /// Like `normalizedPoint` but clamps outside points to the nearest video
    /// edge, so a drag that leaves the letterbox tracks the edge instead of
    /// freezing. Returns nil only for degenerate geometry.
    public static func clampedNormalizedPoint(
        _ point: CGPoint, pixelSize: CGSize, in bounds: CGRect
    ) -> CGPoint? {
        let rect = videoRect(pixelSize: pixelSize, in: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }
}
