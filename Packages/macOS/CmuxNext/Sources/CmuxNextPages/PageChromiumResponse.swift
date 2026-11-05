public import Foundation

/// The answer to a Chromium page's request for one of its dynamic paths
/// (``PageDescriptor/dynamicPrefixes``): what ``PageSchemeHandler`` answers the WebKit page for the
/// same URL. Chromium adds the page's CSP and the other page headers itself.
public nonisolated struct PageChromiumResponse: Sendable, Equatable {
    /// The HTTP status (200, 206 or 416 for a byte range, or 404 when the page has no such resource).
    public var status: Int
    /// The body's MIME type (`image/png`).
    public var mimeType: String
    /// The body.
    public var body: Data
    /// A byte-range answer's `Content-Range` and `Accept-Ranges` (206 or 416 for a video's range);
    /// empty for a whole file. The shim keeps only those two.
    public var rangeHeaders: [String: String]
    /// The page's CSP for this answer, nil for the page's own: the live web loop's dev server policy
    /// (``PageDevServer/csp(for:)``), which lets the page's HMR socket connect.
    public var csp: String?

    /// - Parameters:
    ///   - status: The HTTP status.
    ///   - mimeType: The body's MIME type.
    ///   - body: The body.
    ///   - rangeHeaders: A byte-range answer's `Content-Range` and `Accept-Ranges`.
    public init(status: Int, mimeType: String, body: Data, rangeHeaders: [String: String] = [:], csp: String? = nil) {
        self.status = status
        self.mimeType = mimeType
        self.body = body
        self.rangeHeaders = rangeHeaders
        self.csp = csp
    }

    /// No such resource.
    public static let notFound = PageChromiumResponse(status: 404, mimeType: "text/plain", body: Data())
}
