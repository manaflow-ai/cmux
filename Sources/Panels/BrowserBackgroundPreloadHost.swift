import AppKit

@MainActor
enum BrowserBackgroundPreloadHost {
    @discardableResult
    static func attach(_ presentationView: NSView, to window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        contentView.addSubview(presentationView)
        return contentView
    }
}
