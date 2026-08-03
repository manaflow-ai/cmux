public import AppKit

/// Applies transparent rendering to a native scroll-view hierarchy.
public enum ClearScrollBackground {
    /// Clears the scroll view, clip view, and document-view backing layers.
    @MainActor
    public static func apply(to scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.layer?.isOpaque = false

        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.contentView.layer?.isOpaque = false

        if let documentView = scrollView.documentView {
            documentView.wantsLayer = true
            documentView.layer?.backgroundColor = NSColor.clear.cgColor
            documentView.layer?.isOpaque = false
        }
    }
}
