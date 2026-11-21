public import Foundation

extension URL {
    /// The History page's address, `cmux://history`.
    public nonisolated static let historyPageString = "cmux://history"
    /// The page address (a literal a test parses; /dev/null stands in rather than a trap).
    public nonisolated static let historyPage: URL = URL(string: historyPageString) ?? URL(fileURLWithPath: "/dev/null")

    /// `cmux://history`, with or without a trailing slash, query or fragment.
    public nonisolated var isHistoryPage: Bool {
        scheme?.lowercased() == "cmux" && host()?.lowercased() == "history"
    }
}
