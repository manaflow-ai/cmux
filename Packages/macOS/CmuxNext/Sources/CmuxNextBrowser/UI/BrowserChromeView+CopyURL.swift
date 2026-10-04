public import AppKit

extension BrowserChromeView {
    /// Copy Page URL (Cmd-Shift-C): the page's full URL, as URL and as text
    /// (never the omnibar's elided display). False when the page has none.
    @discardableResult
    public func copyPageURL(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = tab.state.url else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
        return true
    }
}
