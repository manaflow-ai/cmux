public import AppKit
import CmuxNextDesign

// Drag to reorder bar items and drop links onto the bar. The drag carries
// the bookmark id; the drop asks the source to move it (final index), so the
// tree's rule set decides, and the reload after the change redraws the bar.
extension BookmarksBarView: NSDraggingSource {
    func beginDrag(_ item: BookmarkBarItemView, _ event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.node.id, forType: Self.dragType)
        if let url = item.node.url { pasteboardItem.setString(url.absoluteString, forType: .URL) }
        let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = item.bitmapImageRepForCachingDisplay(in: item.bounds).map { rep -> NSImage in
            item.cacheDisplay(in: item.bounds, to: rep)
            let image = NSImage(size: item.bounds.size)
            image.addRepresentation(rep)
            return image
        }
        dragging.setDraggingFrame(item.frame, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let index = insertionIndex(at: point)
        showIndicator(at: index)
        return sender.draggingPasteboard.string(forType: Self.dragType) != nil ? .move : .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropLayer.isHidden = true
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropLayer.isHidden = true
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        let pasteboard = sender.draggingPasteboard
        if let id = pasteboard.string(forType: Self.dragType) {
            // A drop to the right of its own slot counts the item itself once.
            let current = barItems.firstIndex { $0.node.id == id }
            let final = current.map { index > $0 ? index - 1 : index } ?? index
            source?.moveToBar(id, index: final)
            return true
        }
        guard let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme != nil else { return false }
        let title = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? ""
        source?.addToBar(url: url, title: title, index: index)
        return true
    }

    /// The bar slot (0...visible count) nearest `point`.
    func insertionIndex(at point: NSPoint) -> Int {
        let visible = barItems.filter { !$0.isHidden }
        for (index, item) in visible.enumerated() where point.x < item.frame.midX { return index }
        return visible.count
    }

    private func showIndicator(at index: Int) {
        let visible = barItems.filter { !$0.isHidden }
        let x: CGFloat
        if visible.isEmpty {
            x = Metrics.paneChromeInset
        } else if index < visible.count {
            x = visible[index].frame.minX - Metrics.space1 / 2
        } else {
            x = visible[visible.count - 1].frame.maxX + Metrics.space1 / 2
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLayer.frame = CGRect(x: x - 1, y: Metrics.space2, width: 2, height: bounds.height - 2 * Metrics.space2)
        dropLayer.cornerRadius = 1
        dropLayer.isHidden = false
        CATransaction.commit()
    }
}
