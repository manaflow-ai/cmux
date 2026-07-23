import AppKit
import PDFKit

struct FilePreviewPDFViewportSnapshot {
    private let page: PDFPage?
    private let pagePoint: CGPoint?
    private let pageIndex: Int?
    private let pagePointRatio: CGPoint?
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
        let pageIndex = page.flatMap { page -> Int? in
            guard let document = pdfView.document else { return nil }
            let index = document.index(for: page)
            return index >= 0 ? index : nil
        }
        let pagePointRatio = page.flatMap { page -> CGPoint? in
            guard let pagePoint else { return nil }
            let bounds = page.bounds(for: .cropBox)
            return CGPoint(
                x: FilePreviewViewport.normalizedAnchorRatio(
                    pagePoint.x - bounds.minX,
                    length: bounds.width
                ),
                y: FilePreviewViewport.normalizedAnchorRatio(
                    pagePoint.y - bounds.minY,
                    length: bounds.height
                )
            )
        }

        return FilePreviewPDFViewportSnapshot(
            page: page,
            pagePoint: pagePoint,
            pageIndex: pageIndex,
            pagePointRatio: pagePointRatio,
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
        let resolvedPageAndPoint: (PDFPage, CGPoint)?
        if let document = pdfView.document,
           document.pageCount > 0,
           let pageIndex,
           let pagePointRatio,
           let currentPage = document.page(at: min(pageIndex, max(document.pageCount - 1, 0))) {
            let bounds = currentPage.bounds(for: .cropBox)
            resolvedPageAndPoint = (
                currentPage,
                CGPoint(
                    x: bounds.minX + (bounds.width * pagePointRatio.x),
                    y: bounds.minY + (bounds.height * pagePointRatio.y)
                )
            )
        } else if let page,
                  let pagePoint,
                  page.document === pdfView.document {
            resolvedPageAndPoint = (page, pagePoint)
        } else {
            resolvedPageAndPoint = nil
        }
        guard let (resolvedPage, resolvedPoint) = resolvedPageAndPoint else { return nil }
        let pointInPDFView = pdfView.convert(resolvedPoint, from: resolvedPage)
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
