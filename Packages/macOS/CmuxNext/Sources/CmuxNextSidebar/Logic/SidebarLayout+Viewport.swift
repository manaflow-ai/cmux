import AppKit
import CmuxNextDesign

extension SidebarLayout {
    /// Space kept around a revealed active row (close-focus.md).
    static let revealPadding: CGFloat = 8

    /// The rows as `ListViewport` sees them in a viewport `height` tall.
    func viewport(height: CGFloat) -> ListViewport<SidebarRowKey> {
        ListViewport(items: rows.map { .init(id: $0.key, start: $0.y, length: $0.height) },
                     viewport: height, content: max(totalHeight, height))
    }
}

extension NSScrollView {
    /// Moves the content to `y`, animated with `Motion.move` (instant under
    /// Reduce Motion or when not `animated`); `moved` runs after each change.
    func scrollContent(toY y: CGFloat, animated: Bool, moved: @escaping @MainActor () -> Void) {
        let clip = contentView
        let origin = NSPoint(x: clip.bounds.minX, y: y)
        if animated, Motion.animatesMovement {
            Motion.animate(.move, in: clip, { clip.animator().setBoundsOrigin(origin) }, completion: { [weak self] in
                self?.reflectScrolledClipView(clip)
                moved()
            })
        } else {
            clip.setBoundsOrigin(origin)
            reflectScrolledClipView(clip)
        }
        moved()
    }
}
