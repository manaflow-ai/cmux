import Foundation
import Synchronization
import Testing
@testable import CmuxNextBrowserImport

/// Records batches; optionally fails for one profile.
final class RecordingDestination: ImportDestination {
    let batches = Mutex<[ImportBatch]>([])
    let failing: String?

    init(failing: String? = nil) { self.failing = failing }

    func commit(_ batch: ImportBatch) async throws {
        if batch.source.sourceKey == failing { throw CocoaError(.fileWriteNoPermission) }
        batches.withLock { $0.append(batch) }
    }
}

final class RecordingProvisioning: BrowserProfileProvisioning {
    let created = Mutex<[String]>([])
    func createProfile(id: String, name: String, color: String?, source: [String: String]) async throws -> String {
        created.withLock { $0.append("\(id)|\(name)|\(source["profile_dir"] ?? "")") }
        return id
    }
}

@Suite struct ImporterTests {
    func chromeFixture(_ home: FixtureHome) throws -> BrowserSource {
        let root = try home.chromium(.chrome, profiles: [("Default", "Personal"), ("Profile 1", "Work")])
        for dir in ["Default", "Profile 1"] {
            try home.write("""
                {"roots": {"bookmark_bar": {"name": "Bar", "children": [
                  {"type": "url", "name": "\(dir)", "url": "https://\(dir.replacingOccurrences(of: " ", with: "")).example.com/"}]}}}
                """, to: root.appending(path: "\(dir)/Bookmarks"))
            try FixtureHome.sqlite(root.appending(path: "\(dir)/History"), [
                "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)",
                "INSERT INTO urls VALUES(1, 'https://a.example.com/', 'A', 1, 0, 13370000000000000, 0)",
                "INSERT INTO urls VALUES(2, 'https://b.example.com/', 'B', 1, 0, 13370000000000001, 0)",
            ])
        }
        return try #require(BrowserSourceDetector(environment: home.environment).detect(.chrome))
    }

    @Test func importsEachProfileAndReportsProgress() async throws {
        let home = try FixtureHome()
        let source = try chromeFixture(home)
        let plan = ImportPlan(items: source.profiles.map { ImportPlan.Item(profile: $0, kinds: [.bookmarks, .history, .passwords]) })
        #expect(plan.items.allSatisfy { $0.kinds == [.bookmarks, .history] }, "unsupported kinds are dropped")
        let destination = RecordingDestination()
        let fractions = Mutex<[Double]>([])
        let summary = try await BrowserImporter().run(plan, into: destination) { progress in
            fractions.withLock { $0.append(progress.fraction) }
        }
        #expect(summary.counts == ImportCounts(bookmarks: 2, history: 4))
        #expect(summary.batches.map(\.source.targetProfileID) == ["default", "default"])
        #expect(summary.batches.map(\.source.displayName) == ["Google Chrome · Personal", "Google Chrome · Work"])
        let seen = fractions.withLock { $0 }
        #expect(seen == seen.sorted() && seen.last == 1)
        #expect(destination.batches.withLock { $0.count } == 2)
    }

    @Test func aFailingProfileDoesNotStopTheOthers() async throws {
        let home = try FixtureHome()
        let source = try chromeFixture(home)
        let plan = ImportPlan(items: source.profiles.map { ImportPlan.Item(profile: $0, kinds: [.bookmarks]) })
        let summary = try await BrowserImporter().run(plan, into: RecordingDestination(failing: "chrome/Default")) { _ in }
        #expect(summary.batches.map(\.source.profileDirectory) == ["Profile 1"])
        #expect(summary.failures.keys.sorted() == ["chrome/Default"])
    }

    @Test func cancellationStopsTheImport() async throws {
        let home = try FixtureHome()
        let source = try chromeFixture(home)
        let plan = ImportPlan(items: source.profiles.map { ImportPlan.Item(profile: $0, kinds: [.bookmarks, .history]) })
        let destination = RecordingDestination()
        let task = Task { try await BrowserImporter().run(plan, into: destination) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(destination.batches.withLock { $0.isEmpty })
    }

    @Test func provisioningGetsAStableProposedIDPerSource() async throws {
        let home = try FixtureHome()
        let source = try chromeFixture(home)
        let store = ImportedDataStore(directory: home.url.appending(path: "store"))
        let provisioning = RecordingProvisioning()
        let plan = ImportPlan(items: [ImportPlan.Item(profile: source.profiles[1], kinds: [.bookmarks])])
        let first = try await BrowserImporter(provisioning: provisioning, store: store).run(plan, into: RecordingDestination()) { _ in }
        try await store.save(first.batches[0])
        let second = try await BrowserImporter(provisioning: provisioning, store: store).run(plan, into: RecordingDestination()) { _ in }
        let id = first.batches[0].source.proposedProfileID
        #expect(second.batches[0].source.proposedProfileID == id)
        #expect(second.batches[0].source.targetProfileID == id)
        #expect(provisioning.created.withLock { $0 } == ["\(id)|Google Chrome · Work|Profile 1", "\(id)|Google Chrome · Work|Profile 1"])
    }

    @Test func storeReplacesARepeatImportOfTheSameSource() async throws {
        let home = try FixtureHome()
        let store = ImportedDataStore(directory: home.url.appending(path: "store"))
        let record = ImportSourceRecord(browser: .chrome, profileDirectory: "Profile 1", displayName: "Work",
                                        proposedProfileID: "p1", targetProfileID: "default")
        var batch = ImportBatch(source: record)
        batch.bookmarks = [ImportedBookmark(title: "A", url: URL(string: "https://a.example.com")!)]
        try await store.save(batch)
        batch.bookmarks.append(ImportedBookmark(title: "B", url: URL(string: "https://b.example.com")!))
        try await store.save(batch)
        var other = ImportBatch(source: ImportSourceRecord(browser: .firefox, profileDirectory: "Profiles/x", displayName: "FF",
                                                           proposedProfileID: "p2", targetProfileID: "default"))
        other.history = [ImportedHistoryEntry(url: URL(string: "https://c.example.com")!, title: nil, visitCount: 1, lastVisit: Date())]
        try await store.save(other)

        let batches = await store.batches(profile: "default")
        #expect(batches.map(\.counts.total).sorted() == [1, 2])
        #expect(await store.sources().map(\.sourceKey).sorted() == ["chrome/Profile 1", "firefox/Profiles/x"])
        #expect(await store.proposedProfileID(for: "chrome/Profile 1") == "p1")
    }
}
