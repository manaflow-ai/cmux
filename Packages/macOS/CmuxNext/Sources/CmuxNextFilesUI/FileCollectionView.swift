import AppKit

/// The icon layout's collection view: hands unused keys to the pane, opens
/// tiles on double-click and asks the pane for context menus.
final class FileCollectionView: NSCollectionView {
    /// Gets keys first; true when used.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called with the double-clicked tile's index.
    var doubleClick: ((Int) -> Void)?
    /// The context menu for a tile index (nil: the background).
    var menuProvider: ((Int?) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { doubleClick?(path.item) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if let path, !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        return menuProvider?(path?.item)
    }
}
