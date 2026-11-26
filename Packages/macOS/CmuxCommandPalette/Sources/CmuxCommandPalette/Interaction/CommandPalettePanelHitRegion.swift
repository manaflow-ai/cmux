public import AppKit
public import SwiftUI

/// Marks the command palette panel's bounds for AppKit-level outside-click routing.
///
/// The marker never participates in hit testing. The overlay controller queries its
/// frame from the hosting view before deciding whether a mouse-down is outside.
public struct CommandPalettePanelHitRegion: NSViewRepresentable {
    /// Creates a passive panel-bounds marker.
    public init() {}

    /// Creates the passive AppKit marker view.
    ///
    /// - Parameter context: The representable context supplied by SwiftUI.
    /// - Returns: A transparent, non-hit-testing marker view.
    public func makeNSView(context: Context) -> NSView {
        let view = CommandPalettePanelHitRegionView(frame: .zero)
        view.identifier = CommandPalettePanelHitRegionView.interfaceIdentifier
        return view
    }

    /// Keeps the passive marker unchanged across SwiftUI updates.
    ///
    /// - Parameters:
    ///   - nsView: The existing marker view.
    ///   - context: The representable context supplied by SwiftUI.
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// AppKit lookup support for a mounted command-palette panel marker.
public extension NSView {
    /// Returns whether a window-coordinate point is inside the mounted palette panel.
    ///
    /// `nil` means the SwiftUI panel has not mounted its hit-region marker yet.
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
