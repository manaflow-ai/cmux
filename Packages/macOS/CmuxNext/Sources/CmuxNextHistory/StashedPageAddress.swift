public import Foundation

extension URL {
    /// The Stashed Tabs page's address, `cmux://stashed` (with or without a trailing slash, query
    /// or fragment): typed in the address bar or opened as a link, it shows the page.
    public nonisolated var isStashedPage: Bool {
        scheme?.lowercased() == "cmux" && host()?.lowercased() == "stashed"
    }
}
