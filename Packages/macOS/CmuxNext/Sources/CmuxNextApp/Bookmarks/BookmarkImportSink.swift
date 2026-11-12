import CmuxNextBookmarks
import CmuxNextBrowserImport
import Foundation

/// The onboarding import's way in (agreed with the onboarding agent):
/// one folder per source profile at the end of the target profile's
/// Bookmarks Bar, replaced in place when the same source is imported again.
struct BookmarkImportSink: ImportedBookmarkSink {
    weak var service: BookmarkService?

    init(service: BookmarkService) {
        self.service = service
    }

    func replaceImportedBookmarks(_ bookmarks: [ImportedBookmark], source: ImportSourceRecord) async throws {
        let items = bookmarks.map { BookmarkImportItem(title: $0.title, url: $0.url, folderPath: $0.folderPath, created: $0.dateAdded) }
        guard let service else { return }
        // The same "Imported from <Browser> (<profile>)" folder the bookmarks import makes.
        let title = await BookmarkBrowserImport.folderTitle(browser: source.browser, profileName: source.profileName)
        try await service.routed.importSource(items, title: title, sourceKey: source.sourceKey, profile: source.targetProfileID)
    }
}

extension BookmarkService {
    /// Browser imports saved before bookmarks existed become bookmarks once
    /// (a marker file records it, so a folder the user deleted stays deleted).
    func migrateLegacyImports() async {
        guard let store = importStore, let directory else { return }
        let marker = directory.appending(path: "bookmarks-imports-migrated")
        guard await !Self.exists(marker) else { return }
        for record in await store.sources() {
            for batch in await store.batches(profile: record.targetProfileID) where batch.source.sourceKey == record.sourceKey {
                guard batch.kinds.contains(.bookmarks), !batch.bookmarks.isEmpty else { continue }
                let items = batch.bookmarks.map {
                    BookmarkImportItem(title: $0.title, url: $0.url, folderPath: $0.folderPath, created: $0.dateAdded)
                }
                do {
                    try await routed.importSource(items, title: record.displayName, sourceKey: record.sourceKey, profile: record.targetProfileID)
                } catch {
                    logger.error("migrate imported bookmarks \(record.sourceKey, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        await Self.mark(marker, in: directory)
    }

    /// Whether the migration marker is there, off the main actor.
    @concurrent nonisolated private static func exists(_ marker: URL) async -> Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    /// Writes the migration marker, off the main actor.
    @concurrent nonisolated private static func mark(_ marker: URL, in directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
}
