import CmuxNextPages
import CmuxNextRemoteFetch
import Foundation

/// Fetches one remote image for the markdown page's `__image` prefix.
protocol RemoteImageFetching: AnyObject {
    func fetch(_ url: URL) async -> PageResource?
}

/// The guarded fetch (``GuardedRemoteFetch``: one lookup, every address public, the connection
/// pinned to a checked address, redirects checked the same way), then an image type only.
final class GuardedRemoteImages: RemoteImageFetching {
    private let fetcher: GuardedRemoteFetch

    init(resolver: any RemoteAddressResolving = SystemRemoteResolver(), transport: any RemoteFetchTransport = PinnedTLSTransport()) {
        fetcher = GuardedRemoteFetch(maximumBytes: RemoteImagePolicy.maximumBytes, timeout: RemoteImagePolicy.timeout,
                                     accept: GuardedRemoteFetch.imageAccept, resolver: resolver, transport: transport)
    }

    func fetch(_ url: URL) async -> PageResource? {
        guard case .success(let response) = await fetcher.fetch(url),
              let type = RemoteImagePolicy.imageType(response.headers["content-type"]) else { return nil }
        return PageResource(data: response.body, mimeType: type)
    }
}
