public import AppKit
public import PDFKit

/// Visible-page resolution for the file-preview PDF surface, homed on the
/// `PDFView` it inspects.
///
/// Replaces the former caseless `FilePreviewPDFVisiblePageResolver` namespace
/// enum: the resolution operates entirely on a `PDFView` plus its enclosing
/// scroll view, so it lives as methods on `PDFView` per the no-namespace-enum
/// convention. Continuous-scroll mode picks the page dominating the clip (with a
/// document-edge fast path); paged modes defer to `currentPage`.
extension PDFView {
    /// The page nearest the top edge of the visible clip region, sampling
    /// progressively deeper insets before falling back to the current page.
    public func filePreviewTopVisiblePage(scrollView: NSScrollView?) -> PDFPage? {
        guard let scrollView else { return currentPage }
        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else { return currentPage }

        let insetCandidates = [
            CGFloat(8),
            CGFloat(24),
            CGFloat(48),
            min(clipBounds.height * 0.25, 160),
            clipBounds.height * 0.5,
        ]
        for inset in insetCandidates where inset > 0 && inset < clipBounds.height {
            let y = clipView.isFlipped
                ? clipBounds.minY + inset
                : clipBounds.maxY - inset
            let pointInPDFView = convert(CGPoint(x: clipBounds.midX, y: y), from: clipView)
            if let page = page(for: pointInPDFView, nearest: false) {
                return page
            }
        }

        let fallbackY = clipView.isFlipped ? clipBounds.minY + 8 : clipBounds.maxY - 8
        let fallbackPoint = CGPoint(x: clipBounds.midX, y: fallbackY)
        return page(for: convert(fallbackPoint, from: clipView), nearest: true)
            ?? currentPage
    }

    /// The page that should be treated as selected for the current viewport:
    /// a document edge page when scrolled to the top/bottom, otherwise the
    /// dominant sampled page, otherwise the top visible page.
    public func filePreviewSelectedVisiblePage(scrollView: NSScrollView?) -> PDFPage? {
        guard let scrollView else { return currentPage }
        guard let document, document.pageCount > 0 else { return currentPage }

        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else { return currentPage }

        if let documentView = scrollView.documentView,
           let edgePageIndex = Self.filePreviewVerticalDocumentEdgePageIndex(
            pageCount: document.pageCount,
            clipBounds: clipBounds,
            documentBounds: documentView.bounds,
            isFlipped: clipView.isFlipped
           ),
           let page = document.page(at: edgePageIndex) {
            return page
        }

        if let dominantPage = filePreviewDominantVisiblePage(clipView: clipView, clipBounds: clipBounds) {
            return dominantPage
        }

        return filePreviewTopVisiblePage(scrollView: scrollView)
    }

    /// The document edge page index (`0` or `pageCount - 1`) when the clip is
    /// scrolled to the corresponding document edge, otherwise `nil`.
    public static func filePreviewVerticalDocumentEdgePageIndex(
        pageCount: Int,
        clipBounds: CGRect,
        documentBounds: CGRect,
        isFlipped: Bool
    ) -> Int? {
        guard pageCount > 0,
              clipBounds.width > 1,
              clipBounds.height > 1,
              documentBounds.width > 1,
              documentBounds.height > 1,
              documentBounds.height > clipBounds.height else {
            return nil
        }

        let threshold = max(CGFloat(2), min(CGFloat(16), clipBounds.height * 0.05))
        let isAtTop = isFlipped
            ? clipBounds.minY <= documentBounds.minY + threshold
            : clipBounds.maxY >= documentBounds.maxY - threshold
        let isAtBottom = isFlipped
            ? clipBounds.maxY >= documentBounds.maxY - threshold
            : clipBounds.minY <= documentBounds.minY + threshold

        if isAtBottom, !isAtTop {
            return pageCount - 1
        }
        if isAtTop, !isAtBottom {
            return 0
        }
        return nil
    }

    private func filePreviewDominantVisiblePage(
        clipView: NSClipView,
        clipBounds: CGRect
    ) -> PDFPage? {
        guard let document else { return nil }
        let sampleXRatios: [CGFloat] = [0.5, 0.33, 0.67]
        let sampleYRatios: [CGFloat] = [0.5, 0.35, 0.65, 0.2, 0.8]
        var pageScores: [Int: Int] = [:]

        for yRatio in sampleYRatios {
            for xRatio in sampleXRatios {
                let pointInClip = CGPoint(
                    x: clipBounds.minX + (clipBounds.width * xRatio),
                    y: clipBounds.minY + (clipBounds.height * yRatio)
                )
                let pointInPDFView = convert(pointInClip, from: clipView)
                guard let page = page(for: pointInPDFView, nearest: false) else { continue }
                let pageIndex = document.index(for: page)
                guard pageIndex >= 0 else { continue }
                pageScores[pageIndex, default: 0] += Self.filePreviewCenterWeightedScore(for: yRatio)
            }
        }

        let dominantPageIndex = pageScores.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
        return dominantPageIndex.flatMap { document.page(at: $0) }
    }

    private static func filePreviewCenterWeightedScore(for yRatio: CGFloat) -> Int {
        switch abs(yRatio - 0.5) {
        case 0..<0.01:
            4
        case 0..<0.2:
            3
        default:
            1
        }
    }
}
