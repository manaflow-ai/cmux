import AppKit

/// The page a drag out of the omnibar carries (Chrome: drag the location
/// icon to Finder, Mail, a document or another browser): the URL as a URL,
/// as plain text, and the page title as the link name, so a Finder drop
/// makes a `.webloc` named after the page.
struct BrowserURLDragItem {
    /// The link name type Safari, Chrome and Finder read for a dragged URL.
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    var url: URL
    var title: String?

    /// One pasteboard item with the URL, its text and the title.
    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        if let title, !title.isEmpty { item.setString(title, forType: Self.urlNameType) }
        return item
    }
}
