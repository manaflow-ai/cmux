import Foundation

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
        guard hops.last != url, hops.count <= Self.maximumHops else { return }
        hops.append(url)
    }

    /// Why a session with `policy` (`nil`: none) and the working and
    /// temporary directories `fileRoots` may not receive this download, or
    /// `nil`.
    ///
    /// Each URL is judged: a local file by the rule the session's own
    /// navigations follow (``BrowserReplFileSandbox/navigationRefusal(_:roots:)``),
    /// any other by the policy as a navigation started by ``initiator``
    /// (``BrowserReplDomainPolicy/navigationBlockReason(_:initiator:)``), so
    /// a `data:` or opaque `blob:` download a blocked document wrote is
    /// refused too. A request that went through more than ``maximumHops``
    /// URLs is refused, since the record of it is cut short.
    public func refusal(policy: BrowserReplDomainPolicy?, fileRoots: [String]) -> String? {
        guard hops.count <= Self.maximumHops else {
            return "the download went through more than \(Self.maximumHops) addresses"
        }
        for hop in hops {
            let scheme = hop.prefix { $0 != ":" }.lowercased()
            if scheme == "file" {
                if let reason = BrowserReplFileSandbox.navigationRefusal(hop, roots: fileRoots) {
                    return "the download came from \(hop): \(reason)"
                }
                continue
            }
            guard let policy, policy.isActive else { continue }
            let reason: String?
            if let url = URL(string: hop) {
                reason = policy.navigationBlockReason(url, initiator: initiator)
            } else {
                // Not a URL Foundation reads (a `data:` URL with spaces):
                // judged as text, and by the document that wrote it.
                reason = policy.blockReason(hop) ?? initiator.flatMap(policy.blockReason(document:))
            }
            if let reason {
                return "the download came from \(hop), which the domain policy blocks: \(reason)"
            }
        }
        return nil
    }
}
