public import AppKit

/// File-preview viewport geometry math, homed on the value types it produces.
///
/// Replaces the former caseless `FilePreviewViewport` namespace enum: the
/// anchor-ratio computation lives on `CGFloat` (the ratio it produces) and the
/// clamped clip-origin computation lives on `CGPoint` (the origin it produces),
/// per the no-namespace-enum convention. Both the PDF viewport snapshot and the
/// image preview surface anchor zoom/resize operations through these.
extension CGFloat {
    /// Normalizes an offset along an axis of the given length to a `[0, 1]`
    /// ratio, defaulting to the midpoint for degenerate lengths.
    public static func filePreviewNormalizedAnchorRatio(
        _ value: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        guard length > 1 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }
}

extension CGPoint {
    /// Clamps a desired clip-view origin so the anchored document point stays at
    /// the requested clip offset without scrolling past the document edges,
    /// centering each axis whose document length fits inside the clip.
    public static func filePreviewClampedClipOrigin(
        documentPoint: CGPoint,
        anchorOffsetInClip: CGPoint,
        documentBounds: CGRect,
        clipSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: filePreviewClampedAxisOrigin(
                rawOrigin: documentPoint.x - anchorOffsetInClip.x,
                documentMin: documentBounds.minX,
                documentLength: documentBounds.width,
                clipLength: clipSize.width
            ),
            y: filePreviewClampedAxisOrigin(
                rawOrigin: documentPoint.y - anchorOffsetInClip.y,
                documentMin: documentBounds.minY,
                documentLength: documentBounds.height,
                clipLength: clipSize.height
            )
        )
    }

    private static func filePreviewClampedAxisOrigin(
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

/// The vertical anchor a file-preview PDF viewport snapshot pins while the
/// content is rescaled or the sidebar is resized.
public enum FilePreviewPDFViewportAnchor {
    /// Pin the clip's vertical center.
    case center
    /// Pin the clip's top edge.
    case top
}
