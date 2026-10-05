public import Foundation

/// Download paths that running downloads of both engines hold.
public final class BrowserDownloadReservations {
    public static let shared = BrowserDownloadReservations()

    public init() {}
}

/// Where one download is written while it runs and where it lands.
/// Red stub: the download writes its final file directly.
public final class BrowserDownloadPlacement {
    public let temporaryURL: URL
    public let finalURL: URL

    init(finalURL: URL) {
        self.finalURL = finalURL
        temporaryURL = finalURL
    }

    public func finish() throws -> URL { finalURL }

    public func discard() {}
}
