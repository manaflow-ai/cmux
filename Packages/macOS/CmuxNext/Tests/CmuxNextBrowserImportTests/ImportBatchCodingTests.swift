import Foundation
import Testing
@testable import CmuxNextBrowserImport

@Suite struct ImportBatchCodingTests {
    let record = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome · Personal",
                                    proposedProfileID: "p", targetProfileID: "default")

    @Test func kindsRoundTrip() throws {
        var batch = ImportBatch(source: record, kinds: [.bookmarks, .history], importedAt: Date(timeIntervalSince1970: 10))
        batch.history = [ImportedHistoryEntry(url: URL(string: "https://a.example/")!, title: nil, visitCount: 1, lastVisit: Date(timeIntervalSince1970: 1))]
        let decoded = try JSONDecoder().decode(ImportBatch.self, from: JSONEncoder().encode(batch))
        #expect(decoded == batch)
        // Bookmarks were picked even though the source had none.
        #expect(decoded.kinds.contains(.bookmarks))
    }

    /// Files written before `kinds` existed still load, with the kinds that hold data.
    @Test func legacyFileInfersKinds() throws {
        let json = """
            {"source": {"browser": "chrome", "profileDirectory": "Default", "displayName": "x", "proposedProfileID": "p", "targetProfileID": "default"},
             "bookmarks": [{"title": "A", "url": "https://a.example/", "folderPath": []}],
             "history": [], "openTabs": [], "extensions": [], "importedAt": 5}
            """
        let decoded = try JSONDecoder().decode(ImportBatch.self, from: Data(json.utf8))
        #expect(decoded.kinds == [.bookmarks])
        #expect(decoded.bookmarks.count == 1)
    }
}
