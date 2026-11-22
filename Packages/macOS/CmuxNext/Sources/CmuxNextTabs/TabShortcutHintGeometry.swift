public import AppKit

/// Reads visible tab geometry for the window's shortcut hint overlay.
public struct TabShortcutHintGeometry {
    /// Creates a stateless reader of the strip's current layout.
    public init() {}
    /// Returns visible tab rectangles in the order used by numbered selection.
    ///
    /// - Parameter strip: The laid-out tab strip to inspect.
    /// - Returns: Tab identifiers and their rectangles in strip coordinates.
    public func frames(in strip: TabStripView) -> [(TabID, CGRect)] {
        strip.displayed.compactMap { item in
            guard let cell = strip.cells[item.id], cell.layer.opacity > 0.9 else { return nil }
            let rect = strip.tabsClip.convert(cell.frame, to: strip)
            guard strip.bounds.contains(rect), rect.width >= 20 else { return nil }
            return (item.id, rect)
        }
    }
}
