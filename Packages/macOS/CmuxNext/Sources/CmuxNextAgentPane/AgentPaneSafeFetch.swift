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
    /// The same fetch, with every hop (the URL and each redirect) to one of `hosts`
    /// (``GuardedRemoteFetch/isListed(_:in:)``); a hop anywhere else fails it.
    func fetch(_ url: URL, within hosts: Set<String>) async -> Result<Data, AgentPaneReplyError>
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

    /// Sites whose web images load in a reply without a click under `agentPane.images.remote` =
    /// `click`, the one declared list (the page gets it from `link.inspect`'s policy). The click
    /// keeps a site from learning that a reply was read (a tracking pixel, or a prompt-injected
    /// address that carries data out). raw.githubusercontent.com, where PR screenshots and our
    /// `pr-media` branch live, gives a repository's owner no count or log of who fetched a file,
    /// so it tells no one but GitHub. github.com stays behind the click: a release asset's
    /// download count and a repository's traffic page show its owner each fetch. A click-free
    /// load's redirects must stay on this list too (``fetch(_:within:)``). Leo, 2026-10-23, of a
    /// before/after pair whose second image waited on Load image: "i feel like this is a bit lame idk".
    static let clickFreeImageHosts: Set<String> = ["raw.githubusercontent.com"]

    /// Whether the reply image `src` loads without a click under `click`: it is written exactly
    /// `https://<a click-free host>/…` (lowercase, no port, user info, backslash or space before
    /// the path, so the page's WHATWG parse and this one agree), and it parses to that host
    /// (``GuardedRemoteFetch/isListed(_:in:)``).
    static func isClickFree(_ src: String) -> Bool {
        guard clickFreeImageHosts.contains(where: { src.hasPrefix("https://\($0)/") }), let url = URL(string: src) else {
            return false
        }
        return GuardedRemoteFetch.isListed(url, in: clickFreeImageHosts)
    }

    func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError> {
        await Self.fetch(url, with: guarded)
    }

    func fetch(_ url: URL, within hosts: Set<String>) async -> Result<Data, AgentPaneReplyError> {
        var restricted = guarded
        restricted.hosts = hosts
        return await Self.fetch(url, with: restricted)
    }

    private static func fetch(_ url: URL, with guarded: GuardedRemoteFetch) async -> Result<Data, AgentPaneReplyError> {
        switch await guarded.fetch(url) {
        case .success(let response): .success(response.body)
        case .failure(.refused): .failure(.imageRefused)
        case .failure(.tooLarge): .failure(.imageTooLarge)
        case .failure(.failed): .failure(.imageFailed)
        }
    }
}
