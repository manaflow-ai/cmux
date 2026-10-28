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

    /// The most body bytes one answer carries to the Chromium Host: a control message's shared memory
    /// fields together (`kMaxSharedBytes`, ChromiumHost/src/chromium_host_control.h), Chrome's
    /// `IPC::Channel::kMaximumMessageSize` (ipc/ipc_channel.h).
    static let hostBodyLimit = 128 * 1024 * 1024

    /// This answer as one message to the Chromium Host can carry it: a body over ``hostBodyLimit``
    /// becomes a 500 with no body, so the page's request ends now; the remote shim would drop the
    /// message, and the request would wait for an answer that never comes.
    var fittingHostWire: CEFPageResponse {
        body.count <= Self.hostBodyLimit ? self : CEFPageResponse(status: 500, mimeType: "text/plain", body: Data())
    }
}
