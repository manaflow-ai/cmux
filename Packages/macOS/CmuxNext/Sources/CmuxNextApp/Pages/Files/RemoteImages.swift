import CmuxNextPages
import Foundation

/// Fetches one remote image for the markdown page's `__image` prefix.
protocol RemoteImageFetching: AnyObject {
    func fetch(_ url: URL) async -> PageResource?
}

/// What the host fetches for a markdown file's remote images (coordinator decision for S6: the
/// host fetches them, `markdown.remoteImages`, default on, so the page CSP stays strict): only
/// http(s), never a loopback, private, link-local or `.local` host named by a literal, only image
/// types, at most ``maximumBytes``. No cookies or credentials go with the request.
nonisolated enum RemoteImagePolicy {
    static let maximumBytes = 10 * 1024 * 1024
    static let timeout: TimeInterval = 15

    static let imageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml", "image/bmp",
        "image/x-icon", "image/vnd.microsoft.icon", "image/apng",
    ]

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if let octets = ipv4(host) { return !isPrivate(octets) }
        if host.contains(":") { return !isPrivateIPv6(host) }
        return true
    }

    /// The normalized image type of a `Content-Type` value, nil for anything that is not an image.
    static func imageType(_ value: String?) -> String? {
        guard let base = value?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              imageTypes.contains(base) else { return nil }
        return base
    }

    /// The URL as one path component: base64url without padding.
    static func encode(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ component: String) -> URL? {
        var text = component.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func isPrivate(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127): true
        case (172, 16...31): true
        case (224...255, _): true
        default: false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "::1" || lowered == "::" || lowered.hasPrefix("fe80") || lowered.hasPrefix("fc")
            || lowered.hasPrefix("fd") || lowered.hasPrefix("::ffff:")
    }
}

/// The app's fetcher: one ephemeral session with no cookie store, credentials or cache shared with
/// the browser; a redirect is followed only to a URL the policy allows; the body stops at the limit.
final class URLSessionRemoteImages: RemoteImageFetching {
    nonisolated private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        // The completion form: the async form's Objective-C thunk crashes Swift 6.3's SILGen.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, RemoteImagePolicy.allows(url) else { return completionHandler(nil) }
            completionHandler(request)
        }
    }

    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = RemoteImagePolicy.timeout
        configuration.timeoutIntervalForResource = RemoteImagePolicy.timeout * 2
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        return URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
    }()

    func fetch(_ url: URL) async -> PageResource? {
        await Self.download(url)
    }

    @concurrent private static func download(_ url: URL) async -> PageResource? {
        guard RemoteImagePolicy.allows(url) else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let type = RemoteImagePolicy.imageType(http.value(forHTTPHeaderField: "Content-Type")),
              http.expectedContentLength <= Int64(RemoteImagePolicy.maximumBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > RemoteImagePolicy.maximumBytes { return nil }
            }
        } catch {
            return nil
        }
        return PageResource(data: data, mimeType: type)
    }
}
