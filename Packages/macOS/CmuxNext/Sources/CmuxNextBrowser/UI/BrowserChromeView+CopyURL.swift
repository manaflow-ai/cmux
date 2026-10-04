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
