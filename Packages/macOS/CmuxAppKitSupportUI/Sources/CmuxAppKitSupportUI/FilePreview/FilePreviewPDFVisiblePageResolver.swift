public import AppKit
public import PDFKit

/// Resolves which PDF page is visible in the file-preview host by sampling clip-view points
/// through the `PDFView` hit-test. Stateless; reads the views/document it is handed.
@MainActor
public struct FilePreviewPDFVisiblePageResolver {
    /// Creates a stateless visible-page resolver.
    public init() {}

    /// The page nearest the top of the visible clip region, falling back to `pdfView.currentPage`.
    public func topVisiblePage(in pdfView: PDFView, scrollView: NSScrollView?) -> PDFPage? {
        guard let scrollView else { return pdfView.currentPage }
        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else { return pdfView.currentPage }

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
            let pointInPDFView = pdfView.convert(CGPoint(x: clipBounds.midX, y: y), from: clipView)
            if let page = pdfView.page(for: pointInPDFView, nearest: false) {
                return page
            }
        }

        let fallbackY = clipView.isFlipped ? clipBounds.minY + 8 : clipBounds.maxY - 8
        let fallbackPoint = CGPoint(x: clipBounds.midX, y: fallbackY)
        return pdfView.page(for: pdfView.convert(fallbackPoint, from: clipView), nearest: true)
            ?? pdfView.currentPage
    }

    /// The page the user is most likely reading: a document edge page when scrolled to top/bottom,
    /// else the center-weighted dominant sampled page, else `topVisiblePage`.
    public func selectedVisiblePage(in pdfView: PDFView, scrollView: NSScrollView?) -> PDFPage? {
        guard let scrollView else { return pdfView.currentPage }
        guard let document = pdfView.document, document.pageCount > 0 else { return pdfView.currentPage }

        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else { return pdfView.currentPage }

        if let documentView = scrollView.documentView,
           let edgePageIndex = verticalDocumentEdgePageIndex(
            pageCount: document.pageCount,
            clipBounds: clipBounds,
            documentBounds: documentView.bounds,
            isFlipped: clipView.isFlipped
           ),
           let page = document.page(at: edgePageIndex) {
            return page
        }

        if let dominantPage = dominantVisiblePage(in: pdfView, clipView: clipView, clipBounds: clipBounds) {
            return dominantPage
        }

        return topVisiblePage(in: pdfView, scrollView: scrollView)
    }

    func verticalDocumentEdgePageIndex(
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

    private func dominantVisiblePage(
        in pdfView: PDFView,
        clipView: NSClipView,
        clipBounds: CGRect
    ) -> PDFPage? {
        guard let document = pdfView.document else { return nil }
        let sampleXRatios: [CGFloat] = [0.5, 0.33, 0.67]
        let sampleYRatios: [CGFloat] = [0.5, 0.35, 0.65, 0.2, 0.8]
        var pageScores: [Int: Int] = [:]

        for yRatio in sampleYRatios {
            for xRatio in sampleXRatios {
                let pointInClip = CGPoint(
                    x: clipBounds.minX + (clipBounds.width * xRatio),
                    y: clipBounds.minY + (clipBounds.height * yRatio)
                )
                let pointInPDFView = pdfView.convert(pointInClip, from: clipView)
                guard let page = pdfView.page(for: pointInPDFView, nearest: false) else { continue }
                let pageIndex = document.index(for: page)
                guard pageIndex >= 0 else { continue }
                pageScores[pageIndex, default: 0] += centerWeightedScore(for: yRatio)
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

    private func centerWeightedScore(for yRatio: CGFloat) -> Int {
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
