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
