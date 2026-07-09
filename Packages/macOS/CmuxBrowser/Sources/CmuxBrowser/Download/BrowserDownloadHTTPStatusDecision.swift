/// Whether a download response's HTTP status permits saving the payload.
///
/// Produced by `BrowserDownloadFilenameResolver.httpStatusDecision(for:)`. A
/// non-2xx HTTP status rejects the download (the server returned an error body,
/// not the requested file); any non-HTTP response (e.g. a `file:` or `data:`
/// URL) is allowed.
public enum BrowserDownloadHTTPStatusDecision: Equatable, Sendable {
    /// The response status permits saving the downloaded payload.
    case allow
    /// The response carried a non-2xx HTTP status; the download is rejected.
    case reject(statusCode: Int)
}
