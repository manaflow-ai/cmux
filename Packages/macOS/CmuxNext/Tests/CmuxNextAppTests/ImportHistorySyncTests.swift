@testable import CmuxNextBrowserImport
import Foundation
import SQLite3
import Testing

/// Keep in Sync: a synced Chrome profile's history is read again when Chrome
/// writes its `History` database (a kqueue event, no polling), merged into the
/// same saved batch, and handed to the profile's live history; turning sync
/// off stops the watch.
@Suite(.serialized) struct ImportHistorySyncTests {
    /// Every page delivered, per profile, and every URL taken out.
    private actor Delivered {
        private(set) var pages: [String: [ImportedHistoryEntry]] = [:]
        private(set) var forgotten: [URL] = []
        private(set) var calls = 0
        func add(_ profile: String, _ list: [ImportedHistoryEntry], _ gone: [URL]) {
            pages[profile, default: []] += list
            forgotten += gone
            calls += 1
        }
    }

    private static func until(_ condition: () async -> Bool, within timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A Chromium `History` database with the `urls` columns the reader asks for.
    private static func history(_ file: URL, pages: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let microseconds = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        var sql = "CREATE TABLE IF NOT EXISTS urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, "
            + "typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER DEFAULT 0);"
        for (index, page) in pages.enumerated() {
            sql += "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time) VALUES ('\(page)', 'Page', 1, 0, \(microseconds + Int64(index)));"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func aSyncedProfileFollowsItsBrowsersWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "history-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appending(path: "Chrome/Default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let file = profile.appending(path: "History")
        try Self.history(file, pages: ["https://one.example/"])

        let store = ImportedDataStore(directory: root.appending(path: "store", directoryHint: .isDirectory))
        var record = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                        proposedProfileID: "p1", targetProfileID: "p1")
        record.syncedHistoryFile = file
        try await store.save(ImportBatch(source: record, kinds: [.history]))

        let delivered = Delivered()
        let sync = ImportHistorySync(store: store, grants: nil, delay: .milliseconds(50)) { id, pages, gone in await delivered.add(id, pages, gone) }
        await sync.reconcile()
        #expect(await sync.watched == [record.sourceKey])
        // The catch-up read after the watch starts.
        await Self.until { await delivered.pages["p1"]?.count == 1 }
        #expect(await delivered.pages["p1"]?.map(\.url.host) == ["one.example"])

        // Chrome writes a visit: read again, once, into the same batch; only the new page is handed on.
        try Self.history(file, pages: ["https://two.example/"])
        await Self.until { await delivered.pages["p1"]?.count == 2 }
        #expect(await delivered.pages["p1"]?.compactMap(\.url.host) == ["one.example", "two.example"])
        #expect(await store.batches(profile: "p1").map(\.history.count) == [2])

        // A Clear History fences its time off: Chrome still holds one and two, but the next
        // read (a new visit wakes it) keeps only the page visited after the clear.
        await sync.forget(profile: "p1", since: nil)
        #expect(await store.batches(profile: "p1").first?.history.isEmpty == true)
        try await Task.sleep(for: .milliseconds(20))
        try Self.history(file, pages: ["https://three.example/"])
        await Self.until { await delivered.pages["p1"]?.count == 3 }
        #expect(await delivered.pages["p1"]?.last?.url.host == "three.example")
        #expect(await store.batches(profile: "p1").first?.history.compactMap(\.url.host) == ["three.example"])

        try await store.stopSync(profile: "p1")
        await sync.reconcile()
        #expect(await sync.watched.isEmpty)
    }

    /// Browser import turned off while a read is being saved: the saved pages still reach the
    /// profile's history, and on again the catch-up read is not skipped as already read.
    @Test func pausingWhileAReadIsSavedLosesNoPages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "history-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appending(path: "Chrome/Default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let file = profile.appending(path: "History")
        try Self.history(file, pages: ["https://one.example/"])
        let store = ImportedDataStore(directory: root.appending(path: "store", directoryHint: .isDirectory))
        var record = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                        proposedProfileID: "p1", targetProfileID: "p1")
        record.syncedHistoryFile = file
        try await store.save(ImportBatch(source: record, kinds: [.history]))
        let delivered = Delivered()
        let sync = ImportHistorySync(store: store, grants: nil, delay: .milliseconds(50)) { id, pages, gone in await delivered.add(id, pages, gone) }
        await sync.reconcile()
        await Self.until { await delivered.pages["p1"]?.count == 1 }

        // The next read pauses sync between its save and its hand-on.
        await sync.setAfterSave { [weak sync] in
            await sync?.setAfterSave(nil)
            await sync?.setPaused(true)
        }
        try Self.history(file, pages: ["https://two.example/"])
        await Self.until { await delivered.pages["p1"]?.count == 2 }
        #expect(await sync.isPaused)
        #expect(await delivered.pages["p1"]?.compactMap(\.url.host) == ["one.example", "two.example"], "the saved page was handed on")
        #expect(await sync.watched.isEmpty)

        // On again: the catch-up read runs (nothing new to hand on), and a later write is followed.
        await sync.setPaused(false)
        #expect(await sync.watched == [record.sourceKey])
        try await Task.sleep(for: .milliseconds(20))
        try Self.history(file, pages: ["https://three.example/"])
        await Self.until { await delivered.pages["p1"]?.count == 3 }
        #expect(await delivered.pages["p1"]?.last?.url.host == "three.example")
        await sync.stop()
    }

    @Test func removingAProfilesImportsKeepsItsMappingAndStopsSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-remove-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        var record = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                        proposedProfileID: "p1", targetProfileID: "p1")
        record.syncedHistoryFile = root.appending(path: "History")
        var batch = ImportBatch(source: record, kinds: [.history])
        batch.history = [ImportedHistoryEntry(url: URL(fileURLWithPath: "/"), title: nil, visitCount: 1, lastVisit: Date())]
        try await store.save(batch)

        let removed = try await store.removeImported(profile: "p1")
        #expect(removed.map(\.history.count) == [1])
        #expect(await store.batches(profile: "p1").isEmpty)
        #expect(await store.syncedSources().isEmpty)
        #expect(await store.proposedProfileID(for: record.sourceKey) == "p1")
    }

    @Test func clearingHistoryDropsTheImportedPagesInItsRange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-forget-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                                           proposedProfileID: "p1", targetProfileID: "p1"), kinds: [.history])
        let now = Date()
        batch.history = [ImportedHistoryEntry(url: URL(fileURLWithPath: "/old"), title: nil, visitCount: 1, lastVisit: now.addingTimeInterval(-7200)),
                         ImportedHistoryEntry(url: URL(fileURLWithPath: "/new"), title: nil, visitCount: 1, lastVisit: now)]
        try await store.save(batch)

        try await store.forgetHistory(profile: "p1", since: now.addingTimeInterval(-3600))
        #expect(await store.batches(profile: "p1").first?.history.map(\.url.path) == ["/old"])
        try await store.forgetHistory(profile: "p1", since: nil)
        #expect(await store.batches(profile: "p1").first?.history.isEmpty == true)
        // Repeated clears merge into one fence instead of one entry each.
        #expect(await store.sources().first?.clearedRanges?.count == 1)
    }

    @Test func reimportingASourceKeepsItsClearedHistoryOut() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-reimport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        let record = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                        proposedProfileID: "p1", targetProfileID: "p1")
        let now = Date()
        var batch = ImportBatch(source: record, kinds: [.history])
        batch.history = [ImportedHistoryEntry(url: URL(fileURLWithPath: "/old"), title: nil, visitCount: 1, lastVisit: now.addingTimeInterval(-7200)),
                         ImportedHistoryEntry(url: URL(fileURLWithPath: "/new"), title: nil, visitCount: 1, lastVisit: now.addingTimeInterval(-60))]
        try await store.save(batch)
        try await store.forgetHistory(profile: "p1", since: now.addingTimeInterval(-3600))

        // The same source imported again, with the record a fresh import builds (no fences).
        let (saved, _) = try await store.save(batch)
        #expect(saved.history.map(\.url.path) == ["/old"])
        #expect(await store.batches(profile: "p1").first?.history.map(\.url.path) == ["/old"])
        #expect(await store.sources().first?.clearedRanges?.count == 1, "the fence survives the re-import for Keep in Sync")
    }

    @Test func aRemovedPageOrSiteStaysOutOfTheSavedImports() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-remove-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        let then = Date().addingTimeInterval(-600)
        let page = { (url: String, at: Date) in ImportedHistoryEntry(url: URL(string: url)!, title: nil, visitCount: 1, lastVisit: at) }
        var batches: [ImportBatch] = []
        for (directory, profile) in [("Default", "p1"), ("Profile 1", "p2")] {
            var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: directory, displayName: "Google Chrome",
                                                               proposedProfileID: profile, targetProfileID: profile), kinds: [.history])
            batch.history = [page("https://a.example/one", then), page("https://a.example/two", then), page("https://b.example/", then)]
            try await store.save(batch)
            batches.append(batch)
        }
        let urls = { (profile: String) async in await store.batches(profile: profile).first?.history.map(\.url.absoluteString) ?? [] }

        // One page, in one profile: its saved copy goes, the other profile keeps its own.
        try await store.forgetPage(URL(string: "https://a.example/one")!, profile: "p1")
        #expect(await urls("p1") == ["https://a.example/two", "https://b.example/"])
        #expect(await urls("p2").count == 3)

        // A site, in every profile.
        try await store.forgetSite(host: "B.example")
        #expect(await urls("p1") == ["https://a.example/two"])
        #expect(await urls("p2") == ["https://a.example/one", "https://a.example/two"])

        // A re-import leaves them out; a visit made after the removal comes back.
        var again = batches[0]
        again.history.append(page("https://b.example/new", Date().addingTimeInterval(60)))
        let (saved, _) = try await store.save(again)
        #expect(saved.history.map(\.url.absoluteString) == ["https://a.example/two", "https://b.example/new"])
        again.history = [page("https://a.example/one", Date().addingTimeInterval(60))]
        #expect(try await store.save(again).saved.history.count == 1)
    }

    @Test func aRemovedPageStaysOutUnderEverySpellingOfItsURL() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-remove-spelling-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        let then = Date().addingTimeInterval(-600)
        let page = { (url: String) in ImportedHistoryEntry(url: URL(string: url)!, title: nil, visitCount: 1, lastVisit: then) }
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                                           proposedProfileID: "p1", targetProfileID: "p1"), kinds: [.history])
        batch.history = [page("http://www.A.example/One/"), page("https://a.example/one?tab=2")]
        try await store.save(batch)

        // The omnibar shows these as one row (scheme, www, case, trailing slash), so removing it removes both.
        try await store.forgetPage(URL(string: "https://a.example/one")!, profile: "p1")
        #expect(await store.batches(profile: "p1").first?.history.map(\.url.absoluteString) == ["https://a.example/one?tab=2"])
        batch.history = [page("https://www.a.example/ONE"), page("https://a.example/one?tab=2")]
        #expect(try await store.save(batch).saved.history.map(\.url.absoluteString) == ["https://a.example/one?tab=2"])
    }

    @Test func theRemovalFencesStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-fence-bound-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                                           proposedProfileID: "p1", targetProfileID: "p1"), kinds: [.history])
        batch.history = [ImportedHistoryEntry(url: URL(string: "https://a.example/")!, title: nil, visitCount: 1, lastVisit: Date().addingTimeInterval(-60))]
        try await store.save(batch)

        // A Clear History of all time covers every earlier removal, so those fences go.
        try await store.forgetPage(URL(string: "https://a.example/one")!, profile: "p1")
        try await store.forgetSite(host: "b.example")
        try await store.forgetHistory(profile: "p1", since: nil)
        let record = try #require(await store.sources().first)
        #expect(record.removedPages == nil && record.removedSites == nil)
        #expect(record.clearedRanges?.count == 1)

        // Past the limit the oldest removals go; a page saved by an older build is keyed the new way.
        var many = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome", proposedProfileID: "p1", targetProfileID: "p1")
        let base = Date(timeIntervalSince1970: 1_000_000)
        many.removedPages = Dictionary(uniqueKeysWithValues: (0..<(ImportSourceRecord.fenceLimit + 2)).map { ("https://a.example/\($0)", base.addingTimeInterval(Double($0))) })
        many.removedPages?["https://www.a.example/Old/"] = base.addingTimeInterval(1_000_000)
        let compacted = many.compacted()
        #expect(compacted.removedPages?.count == ImportSourceRecord.fenceLimit)
        #expect(compacted.removedPages?["a.example/0"] == nil, "the oldest removal goes first")
        #expect(compacted.removedPages?["a.example/old"] != nil)
    }

    @Test func clearedRangesMerge() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let range = { (start: Double, end: Double) in DateInterval(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end)) }
        let merged = ImportedDataStore.coalesced([range(50, 100), range(0, 10), range(5, 20), range(100, 120)])
        #expect(merged == [range(0, 20), range(50, 120)])
    }
}

/// Remove Imported Browser Data: the profile's saved imports go, its omnibar
/// forgets their pages and its imported bookmarks are emptied.
@Suite(.serialized) struct RemoveImportedDataTests {
    private actor Sink: ImportedBookmarkSink {
        private(set) var replaced: [String: Int] = [:]
        func replaceImportedBookmarks(_ bookmarks: [ImportedBookmark], source: ImportSourceRecord) async throws {
            replaced[source.sourceKey] = bookmarks.count
        }
    }

    private actor Forgotten {
        private(set) var urls: [URL] = []
        func add(_ list: [URL]) { urls += list }
    }

    @Test func removalReportsWhatWentAndEmptiesBookmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-removal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedDataStore(directory: root)
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                                           proposedProfileID: "p1", targetProfileID: "p1"), kinds: [.history, .bookmarks])
        let page = URL(fileURLWithPath: "/page")
        batch.history = [ImportedHistoryEntry(url: page, title: nil, visitCount: 1, lastVisit: Date())]
        batch.bookmarks = [ImportedBookmark(title: "A", url: page)]
        try await store.save(batch)

        let sink = Sink(), forgotten = Forgotten()
        let sync = ImportHistorySync(store: store, grants: nil) { _, _, gone in await forgotten.add(gone) }
        let counts = try await sync.removeImported(profile: "p1", bookmarks: sink)
        #expect(counts == ImportCounts(bookmarks: 1, history: 1))
        #expect(await forgotten.urls == [page])
        #expect(await sink.replaced == [batch.source.sourceKey: 0])
        #expect(await store.batches(profile: "p1").isEmpty)
    }
}

/// Moving a source into another profile takes its bookmarks and pages out of the old one.
@Suite(.serialized) struct ImportMoveTests {
    private actor Log {
        private(set) var bookmarks: [String: Int] = [:]
        private(set) var forgotten: [String: [URL]] = [:]
        func emptied(_ key: String, _ count: Int) { bookmarks[key] = count }
        func forgot(_ profile: String, _ urls: [URL]) { if !urls.isEmpty { forgotten[profile, default: []] += urls } }
    }

    private struct Sink: ImportedBookmarkSink {
        let log: Log
        func replaceImportedBookmarks(_ bookmarks: [ImportedBookmark], source: ImportSourceRecord) async throws {
            await log.emptied(source.targetProfileID, bookmarks.count)
        }
    }

    @Test func aMovedSourceLeavesItsOldProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-move-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Log()
        let sync = ImportHistorySync(store: ImportedDataStore(directory: root), grants: nil) { id, _, gone in await log.forgot(id, gone) }
        let destination = SavingImportDestination(sync: sync, bookmarks: Sink(log: log))
        let page = URL(fileURLWithPath: "/page")
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                                           proposedProfileID: "p1", targetProfileID: "first"), kinds: [.history, .bookmarks])
        batch.history = [ImportedHistoryEntry(url: page, title: nil, visitCount: 1, lastVisit: Date())]
        batch.bookmarks = [ImportedBookmark(title: "A", url: page)]
        try await destination.commit(batch)
        batch.source.targetProfileID = "second"
        try await destination.commit(batch)

        #expect(await log.bookmarks == ["first": 0, "second": 1])
        #expect(await log.forgotten == ["first": [page]])
    }
}
