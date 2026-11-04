public import Foundation

/// Whether a loaded Cloud machine list still answers for `account`: loaded for it, less than `age` ago.
public nonisolated struct CloudListFreshness {
    public nonisolated init() {}
    public static func isCurrent(loadedAt: ContinuousClock.Instant?, loadedFor: [String?]?, account: [String?], now: ContinuousClock.Instant, within age: Duration) -> Bool {
        guard let loadedAt, loadedFor == account else { return false }
        return loadedAt.duration(to: now) < age
    }
}

/// Answers every redirect with "do not follow" (completion-handler form).
public nonisolated final class CloudRefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    override public init() {}

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
