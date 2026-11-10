public import Foundation

public extension URL {
    /// `cmux://bookmarks`, the manager page's address (a literal; /dev/null stands in rather than a trap).
    nonisolated static let bookmarkPage: URL = URL(string: "cmux://bookmarks") ?? URL(fileURLWithPath: "/dev/null")

    /// `cmux://bookmarks`, with or without a trailing slash, query or fragment.
    nonisolated var isBookmarkPage: Bool {
        scheme?.lowercased() == "cmux" && host()?.lowercased() == "bookmarks"
    }
}
