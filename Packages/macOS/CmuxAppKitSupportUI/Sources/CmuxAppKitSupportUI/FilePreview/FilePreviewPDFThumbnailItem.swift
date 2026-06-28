public import AppKit
public import PDFKit

/// `NSCollectionViewItem` for the file-preview PDF thumbnail strip, backed by a
/// ``FilePreviewPDFThumbnailItemView``.
///
/// Selection state from the collection view and the container's active-selection
/// flag are mirrored onto the backing view; ``configure(page:pageNumber:isSelectedForPreview:isSelectionActiveForPreview:)``
/// renders a page thumbnail at ``FilePreviewPDFSizing/thumbnailMaximumSize`` with
/// its 1-based page number.
public final class FilePreviewPDFThumbnailItem: NSCollectionViewItem {
    /// Reuse identifier registered with the thumbnail collection view.
    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("filePreviewPDFThumbnailItem")

    private var thumbnailItemView: FilePreviewPDFThumbnailItemView? {
        view as? FilePreviewPDFThumbnailItemView
    }

    public override var isSelected: Bool {
        didSet {
            thumbnailItemView?.isSelectedForPreview = isSelected
        }
    }

    /// Whether the container's selection is currently active (key); drives the
    /// emphasized vs unemphasized selection appearance of the backing view.
    public var isSelectionActiveForPreview = false {
        didSet {
            thumbnailItemView?.isSelectionActiveForPreview = isSelectionActiveForPreview
        }
    }

    public override func loadView() {
        view = FilePreviewPDFThumbnailItemView()
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailItemView?.configure(image: nil, pageNumber: "")
        thumbnailItemView?.isSelectedForPreview = false
        thumbnailItemView?.isSelectionActiveForPreview = false
    }

    /// Renders `page`'s thumbnail and 1-based `pageNumber`, applying the supplied
    /// selection state.
    public func configure(
        page: PDFPage?,
        pageNumber: Int,
        isSelectedForPreview: Bool,
        isSelectionActiveForPreview: Bool
    ) {
        let thumbnail = page?.thumbnail(of: FilePreviewPDFSizing.thumbnailMaximumSize, for: .cropBox)
        thumbnailItemView?.configure(image: thumbnail, pageNumber: "\(pageNumber)")
        thumbnailItemView?.isSelectedForPreview = isSelectedForPreview
        thumbnailItemView?.isSelectionActiveForPreview = isSelectionActiveForPreview
    }
}
