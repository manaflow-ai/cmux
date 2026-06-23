public import AppKit
public import PDFKit

/// Layout metrics and width derivations for the PDF file-preview sidebar
/// (thumbnail strip and table-of-contents outline).
///
/// `FilePreviewPDFSizing` is a pure value type that owns the sidebar's
/// compile-time layout constants as stored properties and derives preferred /
/// clamped sidebar widths from PDFKit documents and outlines through instance
/// methods. It holds no runtime/mutable state and touches no
/// `Workspace`/`TabManager`/`AppDelegate`: it reads only `PDFDocument`,
/// `PDFPage`, `PDFOutline`, and `NSFont` geometry, so the canonical constant
/// metric set is exposed as the immutable ``preview`` value rather than a
/// stateful singleton.
public struct FilePreviewPDFSizing: Sendable {
    /// Maximum rendered size of a single page thumbnail.
    public let thumbnailMaximumSize: CGSize
    /// Horizontal padding added around the widest sampled thumbnail when sizing
    /// the thumbnail sidebar.
    public let thumbnailHorizontalPadding: CGFloat
    /// Default sidebar width applied before a document-specific width is known.
    public let defaultSidebarWidth: CGFloat
    /// Minimum width for the thumbnail sidebar.
    public let minimumThumbnailSidebarWidth: CGFloat
    /// Minimum width for the outline (table-of-contents) sidebar.
    public let minimumSidebarWidth: CGFloat
    /// Maximum width either sidebar may grow to.
    public let maximumSidebarWidth: CGFloat
    /// Minimum width reserved for the preview content beside the sidebar.
    public let minimumContentWidth: CGFloat

    private let outlineHorizontalPadding: CGFloat
    private let outlineIndentWidth: CGFloat
    private let outlineSampleLimit: Int
    private let thumbnailSampleLimit: Int

    /// The canonical file-preview sidebar metric set.
    public static let preview = FilePreviewPDFSizing(
        thumbnailMaximumSize: CGSize(width: 190, height: 106),
        thumbnailHorizontalPadding: 22,
        defaultSidebarWidth: 128,
        minimumThumbnailSidebarWidth: 104,
        minimumSidebarWidth: 112,
        maximumSidebarWidth: 320,
        minimumContentWidth: 260,
        outlineHorizontalPadding: 34,
        outlineIndentWidth: 16,
        outlineSampleLimit: 100,
        thumbnailSampleLimit: 16
    )

    /// Creates a sizing metric set. The constants default to the canonical
    /// ``preview`` values; callers normally use ``preview`` directly.
    public init(
        thumbnailMaximumSize: CGSize,
        thumbnailHorizontalPadding: CGFloat,
        defaultSidebarWidth: CGFloat,
        minimumThumbnailSidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        maximumSidebarWidth: CGFloat,
        minimumContentWidth: CGFloat,
        outlineHorizontalPadding: CGFloat,
        outlineIndentWidth: CGFloat,
        outlineSampleLimit: Int,
        thumbnailSampleLimit: Int
    ) {
        self.thumbnailMaximumSize = thumbnailMaximumSize
        self.thumbnailHorizontalPadding = thumbnailHorizontalPadding
        self.defaultSidebarWidth = defaultSidebarWidth
        self.minimumThumbnailSidebarWidth = minimumThumbnailSidebarWidth
        self.minimumSidebarWidth = minimumSidebarWidth
        self.maximumSidebarWidth = maximumSidebarWidth
        self.minimumContentWidth = minimumContentWidth
        self.outlineHorizontalPadding = outlineHorizontalPadding
        self.outlineIndentWidth = outlineIndentWidth
        self.outlineSampleLimit = outlineSampleLimit
        self.thumbnailSampleLimit = thumbnailSampleLimit
    }

    /// Returns the preferred thumbnail-sidebar width for a document, sampling up
    /// to ``thumbnailSampleLimit`` pages for the widest thumbnail.
    public func preferredThumbnailSidebarWidth(for document: PDFDocument?) -> CGFloat {
        guard let document, document.pageCount > 0 else {
            return minimumThumbnailSidebarWidth
        }

        let sampleCount = min(document.pageCount, thumbnailSampleLimit)
        let widestThumbnail = (0..<sampleCount).reduce(CGFloat(0)) { current, pageIndex in
            guard let page = document.page(at: pageIndex) else { return current }
            return max(current, thumbnailSize(for: page).width)
        }
        let preferredWidth = ceil(widestThumbnail + thumbnailHorizontalPadding)
        return max(minimumThumbnailSidebarWidth, preferredWidth)
    }

    /// Returns the preferred outline-sidebar width for an outline root, sampling
    /// up to ``outlineSampleLimit`` rows for the widest indented label.
    public func preferredOutlineSidebarWidth(for outlineRoot: PDFOutline?) -> CGFloat {
        guard let outlineRoot, outlineRoot.numberOfChildren > 0 else {
            return minimumSidebarWidth
        }

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var sampledRows = 0
        var widestRow = CGFloat(0)
        measureOutlineChildren(
            of: outlineRoot,
            depth: 0,
            font: font,
            sampledRows: &sampledRows,
            widestRow: &widestRow
        )
        let preferredWidth = ceil(widestRow + outlineHorizontalPadding)
        return max(minimumSidebarWidth, preferredWidth)
    }

    /// Clamps a proposed sidebar width to fit the container while preserving the
    /// minimum content width beside it.
    public func clampedSidebarWidth(
        _ proposedWidth: CGFloat,
        containerWidth: CGFloat,
        dividerThickness: CGFloat,
        minimumWidth: CGFloat? = nil
    ) -> CGFloat {
        let minimumWidth = minimumWidth ?? minimumSidebarWidth
        let availableWidth = max(0, containerWidth - dividerThickness)
        guard availableWidth > 0 else {
            return max(proposedWidth, minimumWidth)
        }

        let maximumWidthForContainer = max(
            minimumWidth,
            min(maximumSidebarWidth, availableWidth - minimumContentWidth)
        )
        return min(max(proposedWidth, minimumWidth), maximumWidthForContainer)
    }

    /// Returns the rendered thumbnail size for a single page, fit within
    /// ``thumbnailMaximumSize`` and accounting for page rotation.
    public func thumbnailSize(for page: PDFPage) -> CGSize {
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return thumbnailMaximumSize
        }

        let normalizedPageSize: CGSize
        if abs(page.rotation) % 180 == 90 {
            normalizedPageSize = CGSize(width: pageBounds.height, height: pageBounds.width)
        } else {
            normalizedPageSize = pageBounds.size
        }
        let widthScale = thumbnailMaximumSize.width / max(normalizedPageSize.width, 1)
        let heightScale = thumbnailMaximumSize.height / max(normalizedPageSize.height, 1)
        let scale = min(widthScale, heightScale)
        return CGSize(
            width: max(1, normalizedPageSize.width * scale),
            height: max(1, normalizedPageSize.height * scale)
        )
    }

    private func measureOutlineChildren(
        of outline: PDFOutline,
        depth: Int,
        font: NSFont,
        sampledRows: inout Int,
        widestRow: inout CGFloat
    ) {
        guard sampledRows < outlineSampleLimit else { return }

        for childIndex in 0..<outline.numberOfChildren {
            guard sampledRows < outlineSampleLimit,
                  let child = outline.child(at: childIndex) else { break }
            sampledRows += 1
            if let label = child.label, !label.isEmpty {
                let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
                widestRow = max(widestRow, labelWidth + (CGFloat(depth) * outlineIndentWidth))
            }
            if child.numberOfChildren > 0 {
                measureOutlineChildren(
                    of: child,
                    depth: depth + 1,
                    font: font,
                    sampledRows: &sampledRows,
                    widestRow: &widestRow
                )
            }
        }
    }
}
