/// Whether a download's originating HTTP response should be saved or rejected.
///
/// `BrowserDownloadFilenameResolver/httpStatusDecision(for:)` returns ``allow``
/// for non-HTTP responses and for 2xx status codes; any other status code maps
/// to ``reject(statusCode:)`` so the download is dropped rather than saving an
/// error page to disk.
///
/// `Sendable` (pure value type) because the decision is computed on the
/// nonisolated download-delegate callback and inspected at the call site.
public enum BrowserDownloadHTTPStatusDecision: Equatable, Sendable {
    /// The response is eligible to be saved.
    case allow

    /// The response carries a non-2xx HTTP status; the associated value is that
    /// status code. The download is rejected.
    case reject(statusCode: Int)
}
