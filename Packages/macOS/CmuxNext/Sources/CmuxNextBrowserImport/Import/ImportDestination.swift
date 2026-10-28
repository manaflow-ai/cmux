public import Foundation
import ImageIO
import UniformTypeIdentifiers
import CmuxNextCompat

/// Creates cmux browser profiles (data-model.md 5). The caller picks the id
/// so a retry finds the same record; returns the profile id to import into.
/// Until browser profile records exist, the App passes `DefaultProfileOnly`.
/// `look` is the source profile's own color and picture, so the new
/// profile looks like the one it came from; an existing id keeps its look.
public protocol BrowserProfileProvisioning: Sendable {
    func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String
}

/// How a source profile looks in its browser: its color (0xRRGGBB) and
/// account picture, when it has them.
public struct SourceProfileLook: Sendable, Equatable {
    public var color: UInt32?
    public var avatar: URL?

    public init(color: UInt32? = nil, avatar: URL? = nil) {
        self.color = color
        self.avatar = avatar
    }

    public init(_ profile: BrowserSourceProfile) {
        self.init(color: profile.color, avatar: profile.avatar)
    }

    /// The picture as a PNG at most `side` pixels on its longest side and
    /// `maxBytes` long (an image icon); nil when there is none or it is not an image.
    public func avatarPNG(side: Int = 256, maxBytes: Int = 256 * 1024) -> Data? {
        guard let avatar, let source = blockingImageSource(url: avatar as CFURL) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), png.length <= maxBytes else { return nil }
        return png as Data
    }
}

/// Keeps every import in the default browser profile; the mapping still
/// records each source's proposed profile id so it can be split later.
public struct DefaultProfileOnly: BrowserProfileProvisioning {
    public init() {}
    public func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String {
        "default"
    }
}

/// Receives each source profile's data after it is read. The App saves it
/// (``ImportedDataStore``) and feeds the live browser (omnibar history).
public protocol ImportDestination: Sendable {
    func commit(_ batch: ImportBatch) async throws
}

/// Saves each imported profile (through ``ImportHistorySync``, which also
/// takes a moved source out of its old profile), gives its bookmarks to the
/// bookmarks model and its pages to the sync's live history (the omnibar).
public struct SavingImportDestination: ImportDestination {
    public let sync: ImportHistorySync
    public var bookmarks: (any ImportedBookmarkSink)?

    public init(sync: ImportHistorySync, bookmarks: (any ImportedBookmarkSink)? = nil) {
        self.sync = sync
        self.bookmarks = bookmarks
    }

    public func commit(_ batch: ImportBatch) async throws {
        let saved = try await sync.save(batch, bookmarks: bookmarks)
        if let bookmarks, batch.kinds.contains(.bookmarks) {
            try await bookmarks.replaceImportedBookmarks(batch.bookmarks, source: batch.source)
        }
        await sync.merge(saved.history, into: batch.source.targetProfileID)
    }
}
