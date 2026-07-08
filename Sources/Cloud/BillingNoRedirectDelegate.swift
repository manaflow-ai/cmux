import Foundation

// URLSession owns delegate callbacks on its internal queues; this delegate has
// no mutable state, so sharing it with the session is safe.
final class BillingNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
