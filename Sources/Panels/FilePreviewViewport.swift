import AppKit

struct FilePreviewViewport {
    func normalizedAnchorRatio(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 1 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }

    func clampedClipOrigin(
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

    private func clampedAxisOrigin(
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
