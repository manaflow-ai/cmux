public import AppKit

/// Where Copy Page URL writes (NSPasteboard in the app, a fake in tests).
public protocol PageURLPasteboard: AnyObject {
    /// Replaces the contents with `url` as a URL and as plain text.
    func writePageURL(_ url: URL)
}

extension NSPasteboard: PageURLPasteboard {
    public func writePageURL(_ url: URL) {
        clearContents()
        writeObjects([url as NSURL])
        setString(url.absoluteString, forType: .string)
    }
}

extension BrowserChromeView {
    /// Copy Page URL (Cmd-Shift-C): the page's full URL, as URL and as text
    /// (never the omnibar's elided display). False when the page has none.
    @discardableResult
    public func copyPageURL(to pasteboard: any PageURLPasteboard = NSPasteboard.general) -> Bool {
        guard let url = tab.state.url else { return false }
        pasteboard.writePageURL(url)
        return true
    }
}

/// Where the page menu's copy rows write: a link (``PageURLPasteboard``),
/// text, an image. NSPasteboard in the app, a fake in tests.
public protocol BrowserPasteboard: PageURLPasteboard {
    /// Replaces the contents with `text`.
    func writeText(_ text: String)
    /// Replaces the contents with `image` (and its address as a URL).
    func writeImage(_ image: NSImage, source: URL)
}

extension NSPasteboard: BrowserPasteboard {
    public func writeText(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }

    public func writeImage(_ image: NSImage, source: URL) {
        clearContents()
        writeObjects([image, source as NSURL])
    }
}
