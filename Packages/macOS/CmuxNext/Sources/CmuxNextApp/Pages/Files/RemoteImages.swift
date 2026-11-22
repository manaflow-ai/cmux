import CmuxNextPages
import Foundation

/// Fetches one remote image for the markdown page's `__image` prefix.
protocol RemoteImageFetching: AnyObject {
    func fetch(_ url: URL) async -> PageResource?
}

/// Resolves a host name to addresses (the app's: getaddrinfo; tests: a fake).
protocol RemoteImageResolving: Sendable {
    func resolve(_ host: String) async throws -> [IPAddress]
}

/// The guarded fetch: checks the URL, resolves its name, refuses unless every address is public,
/// connects to the checked address (``RemoteImageTransport`` never resolves again, so a second DNS
/// answer cannot move the target), and follows at most ``RemoteImagePolicy/maximumRedirects``
/// redirects, each checked the same way.
final class GuardedRemoteImages: RemoteImageFetching {
    private let resolver: any RemoteImageResolving
    private let transport: any RemoteImageTransport

    init(resolver: any RemoteImageResolving = SystemResolver(), transport: any RemoteImageTransport = PinnedTLSTransport()) {
        self.resolver = resolver
        self.transport = transport
    }

    func fetch(_ url: URL) async -> PageResource? {
        var url = url
        var redirects = 0
        // One request, then at most `maximumRedirects` more.
        for _ in 0...RemoteImagePolicy.maximumRedirects + 1 {
            guard RemoteImagePolicy.allows(url), let host = RemoteImagePolicy.host(of: url) else { return nil }
            let addresses: [IPAddress]
            if let literal = IPAddress(literal: host) {
                addresses = [literal]
            } else {
                guard let resolved = try? await resolver.resolve(host) else { return nil }
                addresses = resolved
            }
            guard let address = addresses.first, addresses.allSatisfy(\.isPublic) else { return nil }
            guard let response = try? await transport.send(RemoteImagePolicy.request(for: url, address: address),
                                                           maximumBytes: RemoteImagePolicy.maximumBytes) else { return nil }
            if (300..<400).contains(response.status) {
                redirects += 1
                guard redirects <= RemoteImagePolicy.maximumRedirects, let location = response.headers["location"],
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else { return nil }
                url = next
                continue
            }
            guard response.status == 200, let type = RemoteImagePolicy.imageType(response.headers["content-type"]),
                  response.body.count <= RemoteImagePolicy.maximumBytes else { return nil }
            return PageResource(data: response.body, mimeType: type)
        }
        return nil
    }
}
