public import AppKit

extension TabStripView {
    /// Visible tab rectangles in strip coordinates, for the window's shortcut hint overlay.
    /// The order is the same presented order used by numbered tab selection.
    public var shortcutHintFrames: [(TabID, CGRect)] {
        displayed.compactMap { item in
            guard let cell = cells[item.id], cell.layer.opacity > 0.9 else { return nil }
            let rect = tabsClip.convert(cell.frame, to: self)
            guard bounds.contains(rect), rect.width >= 20 else { return nil }
            return (item.id, rect)
        }
    }
}
