import Foundation

/// Builds HTTP responses for resources served through the diff-viewer URL scheme.
struct MobileDiffHTTPResponseFactory: Sendable {
    func response(
        url: URL,
        mimeType: String,
        contentLength: Int?
    ) -> HTTPURLResponse? {
        var headers = [
            "Content-Type": mimeType.hasPrefix("text/")
                ? "\(mimeType); charset=utf-8"
                : mimeType,
            "Cache-Control": "no-store",
        ]
        if let contentLength {
            headers["Content-Length"] = String(contentLength)
        }
        return HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }
}
