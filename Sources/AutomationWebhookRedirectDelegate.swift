import Foundation

/// Applies the webhook redirect policy without sharing mutable session state.
// Safety: the delegate stores immutable URL/header snapshots; URLSession may
// invoke its callbacks concurrently without any mutable shared state.
final class AutomationWebhookRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalURL: URL
    private let sensitiveHeaderNames: Set<String>

    init(originalURL: URL, sensitiveHeaderNames: Set<String>) {
        self.originalURL = originalURL
        self.sensitiveHeaderNames = sensitiveHeaderNames
    }

    /// Returns a safe request for a redirect destination, or `nil` to reject it.
    nonisolated func requestForRedirect(_ request: URLRequest) -> URLRequest? {
        guard let destinationURL = request.url,
              destinationURL.scheme?.lowercased() == "https" else {
            // Webhook event bodies must never follow a cleartext redirect.
            return nil
        }
        guard !sensitiveHeaderNames.isEmpty else { return request }
        guard !sameOrigin(originalURL, destinationURL) else { return request }

        var sanitized = request
        if let fields = request.allHTTPHeaderFields?.keys {
            for field in fields where sensitiveHeaderNames.contains(field.lowercased()) {
                sanitized.setValue(nil, forHTTPHeaderField: field)
            }
        }
        return sanitized
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(requestForRedirect(request))
    }

    private nonisolated func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private nonisolated func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
