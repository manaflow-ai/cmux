public import AppKit

/// A virtualized grid of file tiles: thumbnails for pictures, poster frames
/// and lengths for movies, newest first as given. Drag tiles out to any app
/// (the file, and for one picture its bytes too), drop files or pictures in
/// (``onDrop``), Space for Quick Look, a context menu and Finder's keys.
/// Selection follows Finder (``FileGridSelection``): click, Cmd-click to
/// add or remove a tile, Shift-click for a run, Cmd-A, Esc; every command
/// runs on the whole selection.
///
/// The view holds no file state of its own: the owner passes the items
/// (``show(_:)``) from its listing, and every file command goes to
/// ``onCommand`` (the owner runs it; the grid changes no files). Only visible tiles load
/// thumbnails, through the shared ``ThumbnailCache``, so thousands of items
/// cost one screenful of renders.
///
/// ```swift
/// let grid = FileGridView(cache: ThumbnailCache())
/// grid.show(listing.items)
/// grid.onCommand = { command, items in commands.perform(command, on: items, in: grid.window) }
/// grid.onDrop = { pasteboard in saver.canSave(pasteboard) }
/// ```
public final class FileGridView: NSView {
    private let cache: ThumbnailCache
    private let scrollView = NSScrollView()
    let collectionView = FileGridCollectionView()
    private let layoutValues = NSCollectionViewFlowLayout()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
    private var itemsByID: [String: FileGridItem] = [:]
    private var order: [String] = []
    /// The file a Shift-click extends from (kept by id, so a relisting does not move it).
    private var anchorID: String?
    private let writer = FileGridPasteboard()

    /// Colors and tile size; a change redraws the visible tiles.
    public var appearanceValues: FileGridAppearance {
        didSet { applyAppearance() }
    }

    /// Shown in the middle while the grid has no items.
    public var emptyText: String = "" {
        didSet { emptyLabel.stringValue = emptyText }
    }

    /// Runs a command (all but Quick Look, which the grid shows itself) on the selected files.
    /// Nil ignores commands.
    public var onCommand: ((FileGridCommand, [FileGridItem]) -> Void)?

    /// Saves a drop; returns whether it took it. Nil refuses drops.
    public var onDrop: ((NSPasteboard) -> Bool)?

    /// Whether a drop is offered: the pasteboard has something to save. Default: files or a picture.
    public var acceptsDrop: (NSPasteboard) -> Bool = { !$0.droppedFileURLs.isEmpty || $0.holdsImage }

    /// Makes a grid.
    ///
    /// - Parameters:
    ///   - cache: the thumbnail cache (share one per app so tiles render once).
    ///   - appearance: colors and tile size.
    public init(cache: ThumbnailCache, appearance: FileGridAppearance = FileGridAppearance()) {
        self.cache = cache
        self.appearanceValues = appearance
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The items shown, in order.
    public var items: [FileGridItem] { order.compactMap { itemsByID[$0] } }

    /// The selected items, in grid order.
    public var selectedItems: [FileGridItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { path in
            order.indices.contains(path.item) ? itemsByID[order[path.item]] : nil
        }
    }

    /// Shows `items` in this order, keeping the selection and scroll
    /// position of items still shown, and redrawing items whose file changed.
    ///
    /// - Parameter items: the files, already sorted.
    public func show(_ items: [FileGridItem]) {
        var next: [String: FileGridItem] = [:]
        next.reserveCapacity(items.count)
        for item in items { next[item.id] = item }
        let changed = items.compactMap { item in itemsByID[item.id].map { $0 == item ? nil : item.id } ?? nil }
        let newOrder = items.map(\.id)
        itemsByID = next
        emptyLabel.isHidden = !items.isEmpty
        guard newOrder != order || !changed.isEmpty else { return }
        order = newOrder
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newOrder, toSection: 0)
        if !changed.isEmpty { snapshot.reloadItems(changed) }
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    /// Selects the item at `path` and scrolls to it (a file just dropped in).
    ///
    /// - Parameter path: the file path.
    public func reveal(path: String) {
        guard let index = order.firstIndex(of: path) else { return }
        applySelection(FileGridSelection().clicking(index, .select))
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    /// The selection by position, with the anchor.
    var selection: FileGridSelection {
        FileGridSelection(indices: Set(collectionView.selectionIndexPaths.map(\.item)),
                          anchor: anchorID.flatMap { order.firstIndex(of: $0) })
    }

    /// Shows `next`: highlights its tiles, remembers its anchor, and follows it in Quick Look.
    func applySelection(_ next: FileGridSelection) {
        anchorID = next.anchor.flatMap { order.indices.contains($0) ? order[$0] : nil }
        let paths = Set(next.indices.filter { order.indices.contains($0) }.map { IndexPath(item: $0, section: 0) })
        if collectionView.selectionIndexPaths != paths { collectionView.selectionIndexPaths = paths }
        collectionView.refreshQuickLook()
    }

    /// Makes the grid the window's first responder (its tab got focus).
    public func focus() {
        window?.makeFirstResponder(collectionView)
    }

    /// Opens or closes Quick Look on the selection.
    public func toggleQuickLook() { collectionView.toggleQuickLook() }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = min(bounds.width - 40, 360)
        let size = emptyLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        emptyLabel.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - size.height) / 2, width: width, height: size.height)
    }

    // MARK: Setup

    private func setUp() {
        layoutValues.minimumInteritemSpacing = 8
        layoutValues.minimumLineSpacing = 8
        layoutValues.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layoutValues
        collectionView.isSelectable = true
        collectionView.focusRingType = .none
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(FileGridCell.self, forItemWithIdentifier: FileGridCell.identifier)
        collectionView.delegate = self
        collectionView.setAccessibilityLabel(FileGridStrings.gridLabel)
        collectionView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.image")])
        // Never .move or .generic outside the app: Finder would move the file out of its folder.
        collectionView.setDraggingSourceOperationMask([.copy, .link], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .generic, .link], forLocal: true)
        collectionView.onCommand = { [weak self] command in self?.run(command) }
        collectionView.menuForSelection = { [weak self] in self?.makeMenu() }
        collectionView.previewURLs = { [weak self] in self?.selectedItems.map(\.url) ?? [] }
        collectionView.onDropHighlight = { [weak self] on in self?.setDropHighlight(on) }
        collectionView.currentSelection = { [weak self] in self?.selection ?? FileGridSelection() }
        collectionView.applySelection = { [weak self] next in self?.applySelection(next) }
        dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.makeItem(withIdentifier: FileGridCell.identifier, for: indexPath)
            if let self, let cell = cell as? FileGridCell, let item = self.itemsByID[id] {
                cell.configure(item, appearance: self.appearanceValues, cache: self.cache, scale: self.window?.backingScaleFactor ?? 2)
            }
            return cell
        }
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        addSubview(scrollView)
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(emptyLabel)
        applyAppearance()
    }

    private func applyAppearance() {
        let side = appearanceValues.tileSide
        layoutValues.itemSize = CGSize(width: side + 12, height: side + 12 + FileGridCell.nameHeight)
        emptyLabel.textColor = appearanceValues.secondaryText
        layoutValues.invalidateLayout()
        for case let cell as FileGridCell in collectionView.visibleItems() {
            guard let item = cell.item else { continue }
            cell.configure(item, appearance: appearanceValues, cache: cache, scale: window?.backingScaleFactor ?? 2)
        }
    }

    private func setDropHighlight(_ on: Bool) {
        scrollView.layer?.borderWidth = on ? 2 : 0
        scrollView.layer?.borderColor = appearanceValues.dropHighlight.cgColor
    }

    // MARK: Commands

    private func run(_ command: FileGridCommand) {
        let selected = selectedItems
        guard command.applies(toSelectionOf: selected.count) else { return }
        if command == .quickLook { return collectionView.toggleQuickLook() }
        onCommand?(command, selected)
    }

    private func makeMenu() -> NSMenu? {
        let count = selectedItems.count
        guard count > 0 else { return nil }
        let menu = NSMenu()
        for entry in FileGridCommand.menuOrder {
            guard let command = entry else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            guard command.applies(toSelectionOf: count) else { continue }
            let item = NSMenuItem(title: FileGridStrings.title(command), action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = FileGridCommand(rawValue: raw) else { return }
        run(command)
    }
}

extension FileGridView: NSCollectionViewDelegate {
    /// AppKit's own selection changes (arrow keys, rubber band): a lone tile becomes the anchor.
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        let selected = collectionView.selectionIndexPaths
        if selected.count == 1, let only = selected.first, order.indices.contains(only.item) { anchorID = order[only.item] }
        self.collectionView.refreshQuickLook()
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        self.collectionView.refreshQuickLook()
    }

    public func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    public func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                               willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        self.collectionView.dragBegan = true
    }

    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard order.indices.contains(indexPath.item), let item = itemsByID[order[indexPath.item]] else { return nil }
        // One dragged picture carries its bytes too; a multi-file drag carries file URLs only.
        let single = collectionView.selectionIndexPaths.count <= 1
        return writer.pasteboardItem(for: item, includeImageData: single)
    }

    public func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                               proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                               dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // A drag from this grid to itself is not a drop (there is no order to change).
        guard onDrop != nil, (draggingInfo.draggingSource as? NSCollectionView) !== collectionView,
              acceptsDrop(draggingInfo.draggingPasteboard) else { return [] }
        proposedDropIndexPath.pointee = IndexPath(item: 0, section: 0) as NSIndexPath
        proposedDropOperation.pointee = .before
        setDropHighlight(true)
        return .copy
    }

    public func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                               indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        setDropHighlight(false)
        return onDrop?(draggingInfo.draggingPasteboard) ?? false
    }
}
