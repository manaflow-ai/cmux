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
        try await MainActor.run {
            // The same "Imported from <Browser> (<profile>)" folder the bookmarks import makes.
            let title = BookmarkBrowserImport.folderTitle(browser: source.browser, profileName: source.profileName)
            try service?.replaceImport(items, title: title, sourceKey: source.sourceKey, profile: source.targetProfileID)
        }
    }
}

extension BookmarkService {
    /// One source's bookmarks replace its folder; none removes it.
    func replaceImport(_ items: [BookmarkImportItem], title: String, sourceKey: String, profile: String) throws {
        guard !items.isEmpty else {
            guard let folder = tree(profile).folder(sourceKey: sourceKey) else { return }
            try apply(.delete(id: folder.id), profile: profile)
            return
        }
        try apply(BookmarkImportPlan.source(title: title, sourceKey: sourceKey, items: items), profile: profile)
    }

    /// Browser imports saved before bookmarks existed become bookmarks once
    /// (a marker file records it, so a folder the user deleted stays deleted).
    func migrateLegacyImports() async {
        guard let store = importStore, let directory else { return }
        let marker = directory.appending(path: "bookmarks-imports-migrated")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for record in await store.sources() {
            for batch in await store.batches(profile: record.targetProfileID) where batch.source.sourceKey == record.sourceKey {
                guard batch.kinds.contains(.bookmarks), !batch.bookmarks.isEmpty else { continue }
                let items = batch.bookmarks.map {
                    BookmarkImportItem(title: $0.title, url: $0.url, folderPath: $0.folderPath, created: $0.dateAdded)
                }
                do {
                    try replaceImport(items, title: record.displayName, sourceKey: record.sourceKey, profile: record.targetProfileID)
                } catch {
                    logger.error("migrate imported bookmarks \(record.sourceKey, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
}
