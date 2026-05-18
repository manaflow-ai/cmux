import AppKit
import PDFKit

enum FilePreviewViewport {
    static func normalizedAnchorRatio(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 1 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }

    static func clampedClipOrigin(
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

enum FilePreviewPDFViewportAnchor {
    case center
    case top
}

enum FilePreviewPDFVisiblePageResolver {
    static func topVisiblePage(in pdfView: PDFView, scrollView: NSScrollView?) -> PDFPage? {
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

    static func selectedVisiblePage(in pdfView: PDFView, scrollView: NSScrollView?) -> PDFPage? {
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

    static func verticalDocumentEdgePageIndex(
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

    private static func dominantVisiblePage(
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

    private static func centerWeightedScore(for yRatio: CGFloat) -> Int {
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

struct FilePreviewPDFViewportSnapshot {
    private let page: PDFPage?
    private let pagePoint: CGPoint?
    private let documentAnchorRatio: CGPoint
    private let anchorOffsetInClip: CGPoint

    static func capture(
        in pdfView: PDFView,
        scrollView: NSScrollView?,
        anchor: FilePreviewPDFViewportAnchor
    ) -> FilePreviewPDFViewportSnapshot? {
        guard let scrollView,
              let documentView = scrollView.documentView else { return nil }

        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else { return nil }

        let anchorY: CGFloat
        switch anchor {
        case .center:
            anchorY = clipBounds.midY
        case .top:
            anchorY = clipView.isFlipped ? clipBounds.minY : clipBounds.maxY
        }

        let anchorInClip = CGPoint(x: clipBounds.midX, y: anchorY)
        let anchorOffsetInClip = CGPoint(
            x: anchorInClip.x - clipBounds.origin.x,
            y: anchorInClip.y - clipBounds.origin.y
        )
        let documentBounds = documentView.bounds
        let anchorInDocument = documentView.convert(anchorInClip, from: clipView)
        let anchorRatio = CGPoint(
            x: FilePreviewViewport.normalizedAnchorRatio(
                anchorInDocument.x - documentBounds.minX,
                length: documentBounds.width
            ),
            y: FilePreviewViewport.normalizedAnchorRatio(
                anchorInDocument.y - documentBounds.minY,
                length: documentBounds.height
            )
        )

        let anchorInPDFView = pdfView.convert(anchorInClip, from: clipView)
        let page = pdfView.page(for: anchorInPDFView, nearest: true)
        let pagePoint = page.map { pdfView.convert(anchorInPDFView, to: $0) }

        return FilePreviewPDFViewportSnapshot(
            page: page,
            pagePoint: pagePoint,
            documentAnchorRatio: anchorRatio,
            anchorOffsetInClip: anchorOffsetInClip
        )
    }

    func restore(in pdfView: PDFView, scrollView: NSScrollView?) {
        guard let scrollView,
              let documentView = scrollView.documentView else { return }

        pdfView.layoutDocumentView()
        pdfView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let targetDocumentPoint = pageAnchoredDocumentPoint(
            in: pdfView,
            documentView: documentView
        ) ?? CGPoint(
            x: documentBounds.minX + (documentBounds.width * documentAnchorRatio.x),
            y: documentBounds.minY + (documentBounds.height * documentAnchorRatio.y)
        )
        let nextOrigin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: targetDocumentPoint,
            anchorOffsetInClip: anchorOffsetInClip,
            documentBounds: documentBounds,
            clipSize: clipView.bounds.size
        )
        clipView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func pageAnchoredDocumentPoint(
        in pdfView: PDFView,
        documentView: NSView
    ) -> CGPoint? {
        guard let page, let pagePoint else { return nil }
        let pointInPDFView = pdfView.convert(pagePoint, from: page)
        let pointInDocument = documentView.convert(pointInPDFView, from: pdfView)
        guard pointInDocument.x.isFinite, pointInDocument.y.isFinite else { return nil }
        return pointInDocument
    }

    #if DEBUG
    func debugSummary(document: PDFDocument?) -> String {
        let pageDescription: String
        if let page, let document {
            let pageIndex = document.index(for: page)
            pageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown"
        } else {
            pageDescription = "nil"
        }
        return "page=\(pageDescription) " +
            "pagePoint=\(Self.debugPoint(pagePoint)) " +
            "ratio=\(Self.debugPoint(documentAnchorRatio)) " +
            "offset=\(Self.debugPoint(anchorOffsetInClip))"
    }

    private static func debugPoint(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return "(\(debugNumber(point.x)),\(debugNumber(point.y)))"
    }

    private static func debugNumber(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.1f", Double(value))
    }
    #endif
}
