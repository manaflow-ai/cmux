import CmuxNextBookmarks
import CmuxNextBrowserImport
import CmuxNextWakeups
import Foundation

/// The onboarding import's way in (agreed with the onboarding agent):
/// one folder per source profile at the end of the target profile's
/// Bookmarks Bar, replaced in place when the same source is imported again.
struct BookmarkImportSink: ImportedBookmarkSink {
    weak var service: BookmarkService?
    /// The app's main-thread scheduler: each source's replace is one posted task on it.
    let mainWork: MainWorkScheduler

    init(service: BookmarkService) {
        self.service = service
        mainWork = service.mainWork
    }

    /// `userBlocking`: the person's onboarding import waits for each source's folder.
    func replaceImportedBookmarks(_ bookmarks: [ImportedBookmark], source: ImportSourceRecord) async throws {
        let items = bookmarks.map { BookmarkImportItem(title: $0.title, url: $0.url, folderPath: $0.folderPath, created: $0.dateAdded) }
        let service = service
        try await mainWork.apply(.userBlocking, owner: "BookmarkImportSink.replace") { () throws -> Void in
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
    /// The marker is read and written on `work`'s files lane and the store off main; each batch's replace is one
    /// posted `visible` task: the bars show the folders it adds.
    @concurrent nonisolated func migrateLegacyImports(store: ImportedDataStore, directory: URL, mainWork: MainWorkScheduler,
                                                      work: BackgroundWork) async {
        let marker = directory.appending(path: "bookmarks-imports-migrated")
        // A refused check (quit began, or the caller was cancelled) is not a missing marker: migrating then
        // would bring back folders the person deleted. The next launch checks again.
        let checked = try? await work.run(.bestEffort, mayBlock: .files) { FileManager.default.fileExists(atPath: marker.path) }
        guard let migrated = checked, !migrated else { return }
        let logger = logger
        for record in await store.sources() {
            for batch in await store.batches(profile: record.targetProfileID) where batch.source.sourceKey == record.sourceKey {
                guard batch.kinds.contains(.bookmarks), !batch.bookmarks.isEmpty else { continue }
                let items = batch.bookmarks.map {
                    BookmarkImportItem(title: $0.title, url: $0.url, folderPath: $0.folderPath, created: $0.dateAdded)
                }
                let (title, sourceKey, profile) = (record.displayName, record.sourceKey, record.targetProfileID)
                await mainWork.apply(.visible, owner: "BookmarkService.migrateImports") { [weak self] () -> Void in
                    do {
                        try self?.replaceImport(items, title: title, sourceKey: sourceKey, profile: profile)
                    } catch {
                        logger.error("migrate imported bookmarks \(sourceKey, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
        // The marker: one empty file, so quit waits for it (a migration is never redone over a deleted folder).
        _ = try? await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }
}
