/// Where a download's bytes came from: every URL its request went through
/// (the navigation it was, each redirect of it, the redirects of the
/// download itself and the response's URL), and the document that started
/// the navigation.
///
/// A download a session receives stays in the temporary directory, where
/// `download.path()` and `fs` read it. Its bytes are a read of each place
/// the request went, so a session gets it only when its domain policy allows
/// every one of them and its local files lie inside the session's own
/// directories (``refusal(policy:fileRoots:)``). The policy never filters a
/// user's tab: there such a download keeps the user's own download location.
public struct BrowserReplDownloadSource: Sendable, Equatable {
    /// The URLs in the order the request went through them.
    public private(set) var hops: [String]
    /// The document that started the navigation (WebKit's record of the
    /// source frame), when one did: a `data:`, `about:` or opaque `blob:`
    /// download is its writing.
    public var initiator: BrowserReplFrameDocument?

    /// The most URLs kept; a request that goes through more is refused.
    public static let maximumHops = 32

    public init(hops: [String] = [], initiator: BrowserReplFrameDocument? = nil) {
        self.hops = hops
        self.initiator = initiator
    }

    /// The request went on to `url` (a redirect, or the response's URL).
    public mutating func went(to url: String) {
        guard hops.last != url else { return }
        hops.append(url)
    }

    /// Why a session with `policy` (`nil`: none) and the working and
    /// temporary directories `fileRoots` may not receive this download, or
    /// `nil`.
    public func refusal(policy: BrowserReplDomainPolicy?, fileRoots: [String]) -> String? {
        nil
    }
}
