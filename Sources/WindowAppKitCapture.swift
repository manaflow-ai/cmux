#if DEBUG
import AppKit
import AVKit
import Foundation
import PDFKit
import Quartz
import WebKit

/// Holds the permission-free AppKit fallback for one window screenshot.
struct WindowAppKitCapture: Sendable {
    let pngData: Data

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

    /// Identifies view hierarchies whose pixels are owned by a system or GPU
    /// compositor rather than ordinary AppKit drawing.
    @MainActor
    static func containsSystemCompositorContent(in view: NSView) -> Bool {
        if view is GhosttyNSView ||
            view is WKWebView ||
            view is AVPlayerView ||
            view is QLPreviewView ||
            view is PDFView {
            return true
        }
        return view.subviews.contains(where: containsSystemCompositorContent)
    }

    /// Returns native children that must be redrawn after a raw external
    /// surface image is composited over AppKit's initial cache.
    @MainActor
    static func nativeOverlayCandidates(inside externalView: NSView) -> [NSView] {
        externalView.subviews.filter { view in
            !view.isHiddenOrHasHiddenAncestor &&
                view.alphaValue > 0 &&
                !containsSystemCompositorContent(in: view)
        }
    }

    /// Returns explicitly owned overlays without treating WebKit's internal
    /// native view hierarchy as cmux UI.
    @MainActor
    static func ownedNativeOverlayCandidates(inside externalView: NSView) -> [NSView] {
        externalView.subviews.filter { view in
            view is WindowScreenshotOwnedNativeOverlay &&
                !view.isHiddenOrHasHiddenAncestor &&
                view.alphaValue > 0 &&
                !containsSystemCompositorContent(in: view)
        }
    }
}
#endif
