import CmuxNextRemoteFetch
import Foundation

/// Fetches a reply's web image for the page, which has no network of its own (CSP
/// `connect-src 'none'`, `img-src data:`). The URL is untrusted reply text, so the fetch follows
/// the network rules of decision D5 through ``GuardedRemoteFetch``: https only; the host is
/// resolved once and every address it resolves to must be public; the connection goes to exactly
/// that checked address (no second lookup, so a DNS rebinding cannot move it), with the URL's
/// host as the TLS server name; each redirect is checked again (at most
/// ``GuardedRemoteFetch/maximumRedirects``); at most ``maximumBytes`` and ``timeout`` (``media``:
/// ``maximumMediaBytes`` and ``mediaTimeout``); no cookies, cache, credentials, proxy or referrer.
protocol AgentPaneImageFetching: Sendable {
    func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError>
}

nonisolated struct AgentPaneSafeFetch: AgentPaneImageFetching {
    static let maximumBytes = 10 << 20
    static let timeout: Duration = .seconds(10)
    /// The cap and timeout of a web video or audio file (``media``).
    static let maximumMediaBytes = 200 << 20
    static let mediaTimeout: Duration = .seconds(120)

    /// The guarded fetch; tests replace its resolver (the one lookup) or its timeout.
    var guarded = GuardedRemoteFetch(maximumBytes: AgentPaneSafeFetch.maximumBytes, timeout: AgentPaneSafeFetch.timeout,
                                     accept: GuardedRemoteFetch.imageAccept)

    /// The fetch for a reply's web video or audio: the same rules, a larger cap, a longer timeout.
    static var media: AgentPaneSafeFetch {
        var fetch = AgentPaneSafeFetch()
        fetch.guarded.maximumBytes = maximumMediaBytes
        fetch.guarded.timeout = mediaTimeout
        fetch.guarded.accept = GuardedRemoteFetch.mediaAccept
        return fetch
    }

    /// Whether `url` may be fetched at all, before any network: https, a host, no user info, not
    /// a local name or a private literal.
    static func isFetchable(_ url: URL) -> Bool { GuardedRemoteFetch.allows(url) }

    func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError> {
        switch await guarded.fetch(url) {
        case .success(let response): .success(response.body)
        case .failure(.refused): .failure(.imageRefused)
        case .failure(.tooLarge): .failure(.imageTooLarge)
        case .failure(.failed): .failure(.imageFailed)
        }
    }
}
