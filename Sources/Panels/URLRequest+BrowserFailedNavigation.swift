import Foundation

extension URLRequest {
    func browserMatchesFailedNavigationURLString(_ failedURL: String) -> Bool {
        guard let requestURL = url else { return false }
        guard !failedURL.isEmpty else { return false }
        guard let failed = URL(string: failedURL) else { return false }
        return BrowserFailedNavigationURL(url: requestURL) == BrowserFailedNavigationURL(url: failed)
    }

    func browserMatchesReplayShape(of other: URLRequest) -> Bool {
        let method = httpMethod?.uppercased() ?? "GET"
        let otherMethod = other.httpMethod?.uppercased() ?? "GET"
        guard method == otherMethod else {
            return false
        }

        guard httpBodyStream == nil, other.httpBodyStream == nil else {
            return false
        }

        return httpBody == other.httpBody
    }
}

private struct BrowserFailedNavigationURL: Equatable {
    let scheme: String?
    let host: String?
    let port: Int?
    let path: String
    let percentEncodedQuery: String?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let normalizedScheme = components.scheme?.lowercased()
        scheme = normalizedScheme
        host = components.host?.lowercased()
        port = components.port ?? Self.defaultPort(for: normalizedScheme)
        path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        percentEncodedQuery = components.percentEncodedQuery
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
