public import Foundation

/// The answer to a Chromium page's request for one of its dynamic paths
/// (``PageDescriptor/dynamicPrefixes``): what ``PageSchemeHandler`` answers the WebKit page for the
/// same URL. Chromium adds the page's CSP and the other page headers itself.
public nonisolated struct PageChromiumResponse: Sendable, Equatable {
    /// The HTTP status (200, or 404 when the page has no such resource).
    public var status: Int
    /// The body's MIME type (`image/png`).
    public var mimeType: String
    /// The body.
    public var body: Data

    /// - Parameters:
    ///   - status: The HTTP status.
    ///   - mimeType: The body's MIME type.
    ///   - body: The body.
    public init(status: Int, mimeType: String, body: Data) {
        self.status = status
        self.mimeType = mimeType
        self.body = body
    }

    /// No such resource.
    public static let notFound = PageChromiumResponse(status: 404, mimeType: "text/plain", body: Data())
}
