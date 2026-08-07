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
}
#endif
