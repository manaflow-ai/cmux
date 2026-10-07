#if canImport(UIKit) && DEBUG
import UIKit

/// DEBUG lab automation for the photo paths, so a headless simulator can be
/// driven without synthesized touches. Each verb calls the same entry point
/// a person's gesture reaches.
extension ConversationViewController {
    public func photoLabCommand(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "drawer":
            presentPhotoDrawer()
            return "ok"
        case "pick":
            guard parts.count == 2, let item = Int(parts[1]), let drawer = photoDrawer else { return "error no drawer" }
            return drawer.labToggle(item: item) ? "ok" : "error no item"
        case "send":
            guard composer.hasContent else { return "error empty" }
            composerDidTapSend(composer)
            return "ok"
        case "viewer":
            let cells = collectionView.visibleCells.compactMap { $0 as? MessageCell }.sorted { $0.frame.maxY > $1.frame.maxY }
            guard let imageView = cells.lazy.compactMap({ $0.imageViews.last { !$0.isHidden && $0.image != nil } }).first else { return "error no photo" }
            presentPhotoViewer(from: imageView)
            return "ok"
        case "close":
            presentedViewController?.dismiss(animated: true)
            return "ok"
        default:
            return "error unknown verb"
        }
    }
}

extension ConversationPhotoGridView {
    func labToggle(item: Int) -> Bool {
        guard let grid = subviews.first(where: { $0 is UICollectionView }) as? UICollectionView,
              item < grid.numberOfItems(inSection: 0) else { return false }
        collectionView(grid, didSelectItemAt: IndexPath(item: item, section: 0))
        return true
    }
}
#endif
