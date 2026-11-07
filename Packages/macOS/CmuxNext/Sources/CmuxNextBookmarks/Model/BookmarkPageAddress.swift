public import Foundation

/// `cmux://bookmarks`, the manager page's address.
public nonisolated enum BookmarkPageAddress {
    public static let string = "cmux://bookmarks"
    /// The page address (a literal a test parses; /dev/null stands in rather than a trap).
    public static let url: URL = URL(string: string) ?? URL(fileURLWithPath: "/dev/null")

    /// `cmux://bookmarks`, with or without a trailing slash, query or fragment.
    public static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "cmux" else { return false }
        return url.host()?.lowercased() == "bookmarks"
    }
}
