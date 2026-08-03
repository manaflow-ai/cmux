import Foundation

/// Records permanent redirect targets before allowing `URLSession` to follow
/// them normally.
///
/// Safety: `URLSession` may call this delegate concurrently. Its only stored
/// value is a `Sendable` recorder backed by thread-safe `AsyncStream` storage.
final class GitHubPullRequestPermanentRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    // Safety: all mutable state is owned by `AsyncStream.Continuation`.
    @unchecked Sendable
{
    private let redirectRecorder: GitHubPullRequestPermanentRedirectRecorder

    init(redirectRecorder: GitHubPullRequestPermanentRedirectRecorder) {
        self.redirectRecorder = redirectRecorder
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard response.statusCode == 301, let redirectURL = request.url else {
            completionHandler(request)
            return
        }

        redirectRecorder.record(redirectURL)
        completionHandler(request)
    }
}
