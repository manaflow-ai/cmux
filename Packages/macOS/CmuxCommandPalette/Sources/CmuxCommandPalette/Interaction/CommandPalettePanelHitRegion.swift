public import AppKit

/// AppKit lookup support for a mounted command-palette panel marker.
public extension NSView {
    /// Returns whether a window-coordinate point is inside the mounted palette panel.
    ///
    /// `nil` means the panel has not mounted its hit-region marker yet.
    ///
    /// - Parameter windowPoint: A point in the receiver's window coordinate space.
    /// - Returns: Whether the point is inside the panel, or `nil` before marker mounting.
    func commandPalettePanelContains(windowPoint: NSPoint) -> Bool? {
        guard let marker = commandPalettePanelHitRegionDescendant(),
              !marker.bounds.isEmpty else { return nil }
        return marker.bounds.contains(marker.convert(windowPoint, from: nil))
    }

    private func commandPalettePanelHitRegionDescendant() -> NSView? {
        if identifier == CommandPalettePanelHitRegionView.interfaceIdentifier {
            return self
        }
        for subview in subviews {
            if let match = subview.commandPalettePanelHitRegionDescendant() {
                return match
            }
        }
        return nil
    }
}
