import Foundation

/// Buffers the latest permanent redirect observed while one GitHub request runs.
struct GitHubPullRequestPermanentRedirectRecorder: Sendable {
    private let redirectURLs: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation

    init() {
        let stream = AsyncStream<URL>.makeStream(bufferingPolicy: .bufferingNewest(1))
        redirectURLs = stream.stream
        continuation = stream.continuation
    }

    func record(_ url: URL) {
        continuation.yield(url)
    }

    func finish() {
        continuation.finish()
    }

    func latestRedirectURL() async -> URL? {
        var iterator = redirectURLs.makeAsyncIterator()
        return await iterator.next()
    }
}
