#if DEBUG
import AppKit
import Foundation

/// Holds an AppKit-rendered PNG and whether every external child layer was composited.
struct WindowAppKitCapture: Sendable {
    let pngData: Data
    let capturedAllExternalContent: Bool

    /// Uses AppKit's frame view so native titlebars, toolbars, and accessories
    /// remain in the image alongside the window's content view.
    @MainActor
    static func rootView(for window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        return contentView.superview ?? contentView
    }

    /// Converts the portion AppKit exposes through every clipping ancestor
    /// into the capture root's coordinate space.
    @MainActor
    static func visibleRect(of view: NSView, through root: NSView) -> NSRect? {
        guard view === root || view.isDescendant(of: root) else { return nil }
        let visibleBounds = view.visibleRect.intersection(view.bounds)
        guard !visibleBounds.isEmpty else { return nil }
        let visibleInRoot = view.convert(visibleBounds, to: root)
            .intersection(root.bounds)
        return visibleInRoot.isEmpty ? nil : visibleInRoot
    }
}
#endif
