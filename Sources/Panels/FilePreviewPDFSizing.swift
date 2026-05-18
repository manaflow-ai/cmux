import AppKit
import PDFKit

enum FilePreviewPDFSizing {
    static let thumbnailMaximumSize = CGSize(width: 190, height: 106)
    static let thumbnailHorizontalPadding: CGFloat = 22
    static let defaultSidebarWidth: CGFloat = 128
    static let minimumThumbnailSidebarWidth: CGFloat = 104
    static let minimumSidebarWidth: CGFloat = 112
    static let maximumSidebarWidth: CGFloat = 320
    static let minimumContentWidth: CGFloat = 260

    private static let outlineHorizontalPadding: CGFloat = 34
    private static let outlineIndentWidth: CGFloat = 16
    private static let outlineSampleLimit = 100
    private static let thumbnailSampleLimit = 16

    static func preferredThumbnailSidebarWidth(for document: PDFDocument?) -> CGFloat {
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

    static func preferredOutlineSidebarWidth(for outlineRoot: PDFOutline?) -> CGFloat {
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

    static func clampedSidebarWidth(
        _ proposedWidth: CGFloat,
        containerWidth: CGFloat,
        dividerThickness: CGFloat,
        minimumWidth: CGFloat = minimumSidebarWidth
    ) -> CGFloat {
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

    static func thumbnailSize(for page: PDFPage) -> CGSize {
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

    private static func measureOutlineChildren(
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
