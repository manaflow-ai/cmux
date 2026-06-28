public import AppKit
public import PDFKit

/// Vertical thumbnail strip for the file-preview PDF sidebar: an
/// `NSScrollView`-hosted ``FilePreviewPDFThumbnailCollectionView`` of
/// ``FilePreviewPDFThumbnailItem`` cells, one per page.
///
/// The container drives it through ``setDocument(_:)``, ``selectPage(at:scrollToVisible:)``,
/// ``reloadPage(at:)``, and ``setSelectionActive(_:)``, queries layout via
/// ``preferredSidebarWidth()``, and routes focus through ``focusResponder()``.
/// Page picks, first-responder changes, and arrow/page-key navigation surface
/// through ``onSelectPage``, ``onFocusChanged``, and ``onPageNavigation``. Item
/// size tracks the scroll view's content width so thumbnails fill the column.
public final class FilePreviewPDFThumbnailSidebarView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    private enum Metrics {
        static let thumbnailHeight = FilePreviewPDFSizing.thumbnailMaximumSize.height
        static let labelHeight: CGFloat = 22
        static let itemSpacing: CGFloat = 12
        static let verticalInset: CGFloat = 24
    }

    private let scrollView = NSScrollView()
    private let collectionView = FilePreviewPDFThumbnailCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var document: PDFDocument?
    private var isApplyingSelection = false
    private var selectedPageIndex: Int?
    private var selectionIsActive = false

    /// Invoked with the page a primary click or keyboard selection picked.
    public var onSelectPage: ((PDFPage) -> Void)?
    /// Invoked when first-responder status is gained (`true`) or lost (`false`).
    public var onFocusChanged: ((Bool) -> Void)?
    /// Invoked with a signed page delta when an arrow/page key requests navigation.
    public var onPageNavigation: ((Int) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        updateItemSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateItemSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateItemSize()
    }

    /// Replaces the displayed document, resets selection, and selects page 0.
    public func setDocument(_ document: PDFDocument?) {
        self.document = document
        selectedPageIndex = nil
        collectionView.reloadData()
        selectPage(at: 0, scrollToVisible: false)
    }

    /// Selects the thumbnail for `pageIndex`, optionally centering it in view.
    public func selectPage(at pageIndex: Int, scrollToVisible: Bool) {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else {
            selectedPageIndex = nil
            collectionView.deselectAll(nil)
            return
        }

        isApplyingSelection = true
        let previousPageIndex = selectedPageIndex
        selectedPageIndex = pageIndex
        let indexPath = IndexPath(item: pageIndex, section: 0)
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [indexPath], scrollPosition: scrollToVisible ? .centeredVertically : [])
        let reloadIndexPaths = [previousPageIndex, selectedPageIndex]
            .compactMap { $0 }
            .filter { $0 >= 0 && $0 < document.pageCount }
            .map { IndexPath(item: $0, section: 0) }
        if !reloadIndexPaths.isEmpty {
            collectionView.reloadItems(at: Set(reloadIndexPaths))
        }
        isApplyingSelection = false
    }

    /// Reloads the thumbnail cell for `pageIndex` (e.g. after a render update).
    public func reloadPage(at pageIndex: Int) {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else { return }
        collectionView.reloadItems(at: [IndexPath(item: pageIndex, section: 0)])
    }

    /// Sets whether the selection is active (key), driving emphasized vs
    /// unemphasized selection appearance on visible items.
    public func setSelectionActive(_ isActive: Bool) {
        guard selectionIsActive != isActive else { return }
        selectionIsActive = isActive
        for item in collectionView.visibleItems() {
            (item as? FilePreviewPDFThumbnailItem)?.isSelectionActiveForPreview = isActive
        }
    }

    /// Sidebar width that fits the widest sampled thumbnail for the document.
    public func preferredSidebarWidth() -> CGFloat {
        FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)
    }

    /// The collection view the container makes first responder for keyboard focus.
    public func focusResponder() -> NSView {
        collectionView
    }

    private func setupView() {
        flowLayout.scrollDirection = .vertical
        flowLayout.minimumLineSpacing = Metrics.itemSpacing
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = NSEdgeInsets(
            top: Metrics.verticalInset,
            left: 0,
            bottom: Metrics.verticalInset,
            right: 0
        )

        collectionView.collectionViewLayout = flowLayout
        collectionView.autoresizingMask = [.width]
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.onFocusChanged = { [weak self] isActive in
            self?.onFocusChanged?(isActive)
        }
        collectionView.onPageNavigation = { [weak self] delta in
            self?.onPageNavigation?(delta)
        }
        collectionView.onPrimaryClickItem = { [weak self] pageIndex in
            self?.selectPageFromPrimaryClick(at: pageIndex)
        }
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(
            FilePreviewPDFThumbnailItem.self,
            forItemWithIdentifier: FilePreviewPDFThumbnailItem.reuseIdentifier
        )

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateItemSize() {
        let itemWidth = thumbnailItemWidth()
        if abs(collectionView.frame.width - itemWidth) > 0.5 {
            collectionView.setFrameSize(NSSize(width: itemWidth, height: collectionView.frame.height))
        }
        let nextSize = thumbnailItemSize(width: itemWidth)
        guard flowLayout.itemSize != nextSize else { return }
        flowLayout.itemSize = nextSize
        flowLayout.invalidateLayout()
    }

    private func thumbnailItemWidth() -> CGFloat {
        let contentWidth = scrollView.contentView.bounds.width
        let scrollWidth = scrollView.bounds.width
        let fallbackWidth = bounds.width
        return max(1, contentWidth, scrollWidth, fallbackWidth)
    }

    private func thumbnailItemSize(width: CGFloat) -> NSSize {
        NSSize(
            width: max(1, width),
            height: Metrics.thumbnailHeight + Metrics.labelHeight + 10
        )
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        document?.pageCount ?? 0
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: FilePreviewPDFThumbnailItem.reuseIdentifier,
            for: indexPath
        ) as? FilePreviewPDFThumbnailItem ?? FilePreviewPDFThumbnailItem()
        let page = document?.page(at: indexPath.item)
        item.configure(
            page: page,
            pageNumber: indexPath.item + 1,
            isSelectedForPreview: indexPath.item == selectedPageIndex,
            isSelectionActiveForPreview: selectionIsActive
        )
        return item
    }

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelection,
              let pageIndex = indexPaths.first?.item,
              let page = document?.page(at: pageIndex) else { return }
        window?.makeFirstResponder(collectionView)
        setSelectionActive(true)
        onSelectPage?(page)
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        thumbnailItemSize(width: thumbnailItemWidth())
    }

    private func selectPageFromPrimaryClick(at pageIndex: Int) {
        guard let document,
              pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        window?.makeFirstResponder(collectionView)
        setSelectionActive(true)
        selectPage(at: pageIndex, scrollToVisible: false)
        onSelectPage?(page)
    }
}
