import Foundation

/// The result of best-effort persisting a `browser.screenshot` capture to disk.
///
/// Both fields are `nil` when the temp-file write failed; the caller still has
/// the base64 payload to return, so a persistence failure never fails the RPC.
/// When the write succeeded, ``filePath`` is the absolute filesystem path and
/// ``fileURL`` is its `file://` URL string, matching the `path`/`url` keys the
/// former `v2BrowserScreenshot` reply carried.
public struct BrowserScreenshotPersistence: Sendable, Equatable {
    /// The absolute filesystem path of the written PNG, or `nil` on failure.
    public let filePath: String?

    /// The `file://` URL string of the written PNG, or `nil` on failure.
    public let fileURL: String?

    /// Creates a persistence result.
    /// - Parameters:
    ///   - filePath: the absolute path of the written file, or `nil`.
    ///   - fileURL: the `file://` URL string of the written file, or `nil`.
    public init(filePath: String?, fileURL: String?) {
        self.filePath = filePath
        self.fileURL = fileURL
    }
}
