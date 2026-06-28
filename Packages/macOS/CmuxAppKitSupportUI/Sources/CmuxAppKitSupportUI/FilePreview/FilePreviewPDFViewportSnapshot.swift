public import AppKit
public import PDFKit

/// A captured file-preview PDF scroll position, expressed as a page-anchored point plus a
/// document-relative ratio, so it can be restored faithfully after the document relays out
/// (e.g. when the thumbnail sidebar resizes). Value type; holds only the captured anchors.
@MainActor
public struct FilePreviewPDFViewportSnapshot {
    private let page: PDFPage?
    private let pagePoint: CGPoint?
    private let documentAnchorRatio: CGPoint
    private let anchorOffsetInClip: CGPoint

    /// Captures the current viewport anchored at `anchor`, or `nil` when there is no laid-out
    /// document/clip to anchor against.
    public static func capture(
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

    /// Restores the captured viewport into `pdfView`/`scrollView`, preferring the page-anchored
    /// point and falling back to the document-relative ratio, then scrolling the clip into place.
    public func restore(in pdfView: PDFView, scrollView: NSScrollView?) {
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
    /// A compact one-line description of the captured anchors, for resize-probe logging.
    public func debugSummary(document: PDFDocument?) -> String {
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
