public import Foundation

/// A cmux page's generated file, as its tab's ``CEFTab/pageResources`` answers it. The shim adds
/// the page's CSP and the other page headers.
public nonisolated struct CEFPageResponse: Sendable, Equatable {
    /// The HTTP status (200, or 404).
    public var status: Int
    /// The body's MIME type.
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

    /// No such file.
    public static let notFound = CEFPageResponse(status: 404, mimeType: "text/plain", body: Data())
}
