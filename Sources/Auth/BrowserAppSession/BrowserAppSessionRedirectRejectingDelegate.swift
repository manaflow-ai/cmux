import Foundation

/// Prevents the handoff exchange from following server redirects.
///
/// Safety: `URLSession` may call this stateless delegate concurrently. It owns
/// no mutable state and completes each callback using only the callback inputs.
final class BrowserAppSessionRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    // Safety: this delegate is stateless and each callback is self-contained.
    @unchecked Sendable
{
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
