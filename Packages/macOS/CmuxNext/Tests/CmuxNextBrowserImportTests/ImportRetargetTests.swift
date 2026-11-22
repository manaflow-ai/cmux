import Foundation
import Testing
@testable import CmuxNextBrowserImport

/// Imports made before browser profiles existed went into `default`; each
/// source moves into its own proposed browser profile once (data-model.md 5).
@Suite struct ImportRetargetTests {
    func batch(_ directory: String, proposed: String, url: String) -> ImportBatch {
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: directory, displayName: "Chrome · \(directory)",
                                                           proposedProfileID: proposed, targetProfileID: "default"))
        batch.history = [ImportedHistoryEntry(url: URL(string: url)!, title: nil, visitCount: 1, lastVisit: Date())]
        return batch
    }

    @Test func sourcesStillInDefaultMoveToTheirProposedProfile() async throws {
        let home = try FixtureHome()
        let store = ImportedDataStore(directory: home.url.appending(path: "store"))
        try await store.save(batch("Default", proposed: "p1", url: "https://a.example.com"))
        try await store.save(batch("Profile 1", proposed: "p2", url: "https://b.example.com"))

        let pending = await store.sourcesInDefaultProfile()
        #expect(pending.map(\.proposedProfileID).sorted() == ["p1", "p2"])
        for record in pending { try await store.retarget(record.sourceKey, to: record.proposedProfileID) }

        #expect(await store.batches(profile: "default").isEmpty)
        #expect(await store.batches(profile: "p1").map(\.history.first?.url.host) == ["a.example.com"])
        #expect(await store.batches(profile: "p2").first?.source.targetProfileID == "p2")
        #expect(await store.sources().map(\.targetProfileID).sorted() == ["p1", "p2"])
        #expect(await store.sourcesInDefaultProfile().isEmpty)
    }

    @Test func retargetingAnUnknownSourceIsANoOp() async throws {
        let home = try FixtureHome()
        let store = ImportedDataStore(directory: home.url.appending(path: "store"))
        try await store.retarget("chrome/Nope", to: "p9")
        #expect(await store.sources().isEmpty)
    }
}
