import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistoryEntryTests {
    @Test func decodesLegacySnapshotWithoutTypedFields() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","url":"https://go.dev/","title":"Go","lastVisited":0,"visitCount":3}]
        """
        let entries = try JSONDecoder().decode([BrowserHistoryEntry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].typedCount == 0)
        #expect(entries[0].lastTypedAt == nil)
        #expect(entries[0].visitCount == 3)
    }

    @Test func roundTripsThroughCodable() throws {
        let entry = BrowserHistoryEntry(
            id: UUID(),
            url: "https://example.com/foo",
            title: "Foo",
            lastVisited: Date(timeIntervalSince1970: 1000),
            visitCount: 2,
            typedCount: 1,
            lastTypedAt: Date(timeIntervalSince1970: 900)
        )
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        #expect(decoded == [entry])
    }
}
