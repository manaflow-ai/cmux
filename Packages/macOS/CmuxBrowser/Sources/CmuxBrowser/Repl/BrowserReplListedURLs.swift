/// The URLs one session reads in `tabs.list` and `history.search` rows.
///
/// A tab's URL can carry a credential (a sign-in link's `code`, a signed
/// download's `X-Amz-Signature`, a `user:password@`). The session that
/// created the tab navigated it and holds those values already; any other
/// tab is another session's or the user's, and its URL reaches the reader
/// with the credential values replaced, as network events do
/// (``Swift/String/redactingBrowserReplURLCredentials()``). History rows
/// say nothing of who visited them (the user and every session share the
/// history), so theirs are always replaced.
public struct BrowserReplListedURLs: Sendable {
    /// The session that lists.
    public let reader: String

    public init(reader: String) {
        self.reader = reader
    }

    /// A `tabs.list` row as the reader gets it.
    /// - Parameter creator: The live session that created the tab, or
    ///   `nil` for a user's tab.
    public func tabRow(_ row: [String: Any], creator: String?) -> [String: Any] {
        row
    }

    /// A `history.search` row as the reader gets it.
    public func historyRow(_ row: [String: Any]) -> [String: Any] {
        row
    }
}
