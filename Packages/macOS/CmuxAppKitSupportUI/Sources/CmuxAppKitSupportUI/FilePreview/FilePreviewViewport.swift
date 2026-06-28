public import AppKit

/// Pure viewport clamp/anchor geometry for the file-preview PDF host. Stateless; operates
/// on the document/clip rectangles it is handed and returns the clamped scroll origin.
public enum FilePreviewViewport {
    /// The position of `value` along `length`, normalized to `0...1` (`0.5` when degenerate).
    public static func normalizedAnchorRatio(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 1 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }

    /// The clip-view origin that places `documentPoint` under `anchorOffsetInClip`, clamped so
    /// the clip stays within (or centered on) the document bounds on each axis.
    public static func clampedClipOrigin(
        documentPoint: CGPoint,
        anchorOffsetInClip: CGPoint,
        documentBounds: CGRect,
        clipSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: clampedAxisOrigin(
                rawOrigin: documentPoint.x - anchorOffsetInClip.x,
                documentMin: documentBounds.minX,
                documentLength: documentBounds.width,
                clipLength: clipSize.width
            ),
            y: clampedAxisOrigin(
                rawOrigin: documentPoint.y - anchorOffsetInClip.y,
                documentMin: documentBounds.minY,
                documentLength: documentBounds.height,
                clipLength: clipSize.height
            )
        )
    }

    private static func clampedAxisOrigin(
        rawOrigin: CGFloat,
        documentMin: CGFloat,
        documentLength: CGFloat,
        clipLength: CGFloat
    ) -> CGFloat {
        guard documentLength.isFinite, clipLength.isFinite, documentLength > 0, clipLength > 0 else {
            return documentMin
        }
        if documentLength <= clipLength {
            return documentMin + ((documentLength - clipLength) * 0.5)
        }
        let minimumOrigin = documentMin
        let maximumOrigin = documentMin + documentLength - clipLength
        return min(max(rawOrigin, minimumOrigin), maximumOrigin)
    }
}
