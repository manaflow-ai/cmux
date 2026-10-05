/// The URLs one session reads in `tabs.list`, `frames.list` and
/// `history.search` rows.
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
        creator == reader ? row : Self.redactingURL(row)
    }

    /// A `frames.list` row as the reader gets it.
    /// - Parameters:
    ///   - creator: The live session that created the tab, or `nil` for a
    ///     user's tab.
    ///   - blocked: Whether the reader's domain policy blocks the frame.
    ///
    /// A frame's URL is redacted as its tab's is, and also in a tab the
    /// reader created when its policy blocks the frame: the page, not the
    /// reader, put that URL there, and the reader may not read the frame.
    public func frameRow(_ row: [String: Any], creator: String?, blocked: Bool) -> [String: Any] {
        creator == reader && !blocked ? row : Self.redactingURL(row)
    }

    /// A `history.search` row as the reader gets it.
    public func historyRow(_ row: [String: Any]) -> [String: Any] {
        Self.redactingURL(row)
    }

    private static func redactingURL(_ row: [String: Any]) -> [String: Any] {
        guard let url = row["url"] as? String else { return row }
        var redacted = row
        redacted["url"] = url.redactingBrowserReplURLCredentials()
        return redacted
    }
}
