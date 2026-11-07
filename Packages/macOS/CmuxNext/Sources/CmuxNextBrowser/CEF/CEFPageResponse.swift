public import Foundation

/// A cmux page's generated file, as its tab's ``CEFTab/pageResources`` answers it. The shim adds
/// the page's CSP and the other page headers.
public nonisolated struct CEFPageResponse: Sendable, Equatable {
    /// The HTTP status (200, 206 or 416 for a byte range, or 404).
    public var status: Int
    /// The body's MIME type.
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

    /// No such file.
    public static let notFound = CEFPageResponse(status: 404, mimeType: "text/plain", body: Data())
}
