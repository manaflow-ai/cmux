import Testing
@testable import MessagesLabHome

/// a1317, 2026-11-21: a custom part's payload is JSON of its value, and JSON objects have no key order unless the
/// encoder sorts them. Two table cards of one table compared unequal now and then (HomeStreamMapperTests failed at
/// random once the streamed reply drew its table as a card), and Home's part diff saw a change in a card that had
/// none. One value is one payload, byte for byte.
@MainActor struct HomeCustomPartPayloadTests {
    @Test func oneTableIsOnePayloadEveryTime() throws {
        let raw = "| | Before | After |\n|---|---|---|\n| Light | a | b |\n| Dark | c | d |"
        let table = try #require(HomeTableSplitter().segments(in: raw).lazy.compactMap { segment -> HomeTable? in
            if case .table(let table, _) = segment { return table }
            return nil
        }.first)
        let value = HomeTableRowProvider.Payload(raw: raw, table: table)
        let first = try CustomPart(kind: HomeTableRowProvider.kind, version: 1, value: value)
        // A dictionary's order can follow its storage's address: keep every encode's neighbours alive, so each one
        // gets new memory, as two encodes far apart in a running app do.
        var kept: [Any] = []
        var differing = 0
        for i in 0..<500 {
            kept.append([String: Int](uniqueKeysWithValues: (0..<(i % 37 + 1)).map { ("k\($0)", $0) }))
            let again = try CustomPart(kind: HomeTableRowProvider.kind, version: 1, value: value)
            kept.append(again)
            if again != first { differing += 1 }
        }
        #expect(differing == 0, "\(differing) of 500 encodes of one table gave other bytes")
        #expect(kept.count == 1000)
    }
}
