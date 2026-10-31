import AppKit
import CmuxNextDesign
import CmuxNextFiles

/// The icon layout: an `NSCollectionView` grid of tiles. Like the list, only
/// the tiles on screen exist and only they ask for thumbnails.
@MainActor
final class FileIconGridView: NSObject, FileContentView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let view: NSView
    var focusView: NSView { collection }
    /// Tile edge in points (the icon-size slider).
    var tileSize: CGFloat = 96 {
        didSet {
            guard oldValue != tileSize else { return }
            layout.itemSize = NSSize(width: tileSize, height: tileSize + 32)
            collection.reloadData()
        }
    }
    private let scroll = NSScrollView()
    private let collection = FileCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let actions: FilesPaneActions
    private let icons: FileIconProvider
    private var entries: [FileEntry] = []
    private var folder: URL?
    private var applyingSelection = false
    private var fontSize = TypeScale.caption

    init(actions: FilesPaneActions, icons: FileIconProvider, tileSize: CGFloat = 96) {
        self.actions = actions
        self.icons = icons
        self.tileSize = tileSize
        view = scroll
        super.init()
        layout.itemSize = NSSize(width: tileSize, height: tileSize + 32)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.focusRingType = .none
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collection.keyHandler = { [weak self] event in self?.actions.key(event) ?? false }
        collection.doubleClick = { [weak self] index in
            guard let self, index < self.entries.count else { return }
            self.actions.activate(self.entries[index])
        }
        collection.menuProvider = { [weak self] index in
            guard let self else { return nil }
            return self.actions.menu(index.map { $0 < self.entries.count ? self.entries[$0] : nil } ?? nil)
        }
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        SystemScrollers.follow(scroll)
    }

    func show(_ entries: [FileEntry], of folder: URL, selection: Set<String>) {
        let same = self.folder == folder && self.entries == entries
        self.entries = entries
        self.folder = folder
        if !same { collection.reloadData() }
        if fontSize != TypeScale.caption {
            fontSize = TypeScale.caption
            for case let item as FileIconItem in collection.visibleItems() { item.refreshTypography() }
        }
        var paths = Set<IndexPath>()
        if !selection.isEmpty {
            for (index, entry) in entries.enumerated() where selection.contains(entry.name) { paths.insert(IndexPath(item: index, section: 0)) }
        }
        guard paths != collection.selectionIndexPaths else { return }
        applyingSelection = true
        collection.selectionIndexPaths = paths
        applyingSelection = false
        if let last = paths.max() { collection.scrollToItems(at: [last], scrollPosition: .nearestHorizontalEdge) }
    }

    func reveal(_ name: String) {
        guard let index = entries.firstIndex(where: { $0.name == name }) else { return }
        collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    func beginRename(_ name: String) {
        // Icon tiles rename through the pane's rename sheet (FilesPaneView).
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath)
        if let tile = item as? FileIconItem, indexPath.item < entries.count {
            tile.show(entries[indexPath.item], size: tileSize, icons: icons)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { report(cursor: indexPaths.max()) }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { report(cursor: nil) }

    private func report(cursor: IndexPath?) {
        guard !applyingSelection else { return }
        let names = Set(collection.selectionIndexPaths.compactMap { $0.item < entries.count ? entries[$0.item].name : nil })
        actions.select(names, cursor.flatMap { $0.item < entries.count ? entries[$0.item].name : nil })
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        indexPath.item < entries.count ? entries[indexPath.item].url as NSURL : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, index < entries.count, entries[index].kind == .folder { return .generic }
        dropOperation.pointee = .before
        return .generic
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = FilePasteboard.fileURLs(draggingInfo.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let target = dropOperation == .on && indexPath.item < entries.count && entries[indexPath.item].kind == .folder
            ? entries[indexPath.item].url : nil
        let flags = NSEvent.modifierFlags
        actions.drop(urls, target, flags.contains(.option), flags.contains(.command))
        return true
    }
}
