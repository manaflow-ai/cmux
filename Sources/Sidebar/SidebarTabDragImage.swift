import AppKit

extension SidebarTabDragSourceCoordinator {
    /// Captures the live rendered row under the transparent drag anchor so the
    /// drag preview matches the current row appearance (icon, title, selection
    /// and hover background). Mirrors `SidebarWorkspaceTableController.workspaceDragImage`.
    /// `frame` is in `view`'s local coordinates. Nil-tolerant: `beginDrag`
    /// proceeds without a preview and AppKit falls back to a generic image.
    func dragImage(view: NSView, frame: NSRect) -> NSImage? {
        guard let contentView = view.window?.contentView else { return nil }
        let contentFrame = view.convert(frame, to: contentView)
        guard contentFrame.width > 0, contentFrame.height > 0,
              let representation = contentView.bitmapImageRepForCachingDisplay(in: contentFrame) else {
            return nil
        }
        contentView.cacheDisplay(in: contentFrame, to: representation)
        let image = NSImage(size: frame.size)
        image.addRepresentation(representation)
        return image
    }
}
