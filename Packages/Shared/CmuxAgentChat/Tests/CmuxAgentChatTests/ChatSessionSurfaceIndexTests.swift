import Testing

@testable import CmuxAgentChat

@Suite("Chat session surface index")
struct ChatSessionSurfaceIndexTests {
    private struct Record {
        let sessionID: String
        var surfaceID: String?
    }

    @Test("indexed candidates stay equivalent to a full record scan")
    func behaviorParityWithScan() {
        var records: [String: Record] = [:]
        var index = ChatSessionSurfaceIndex<String>()

        func expectParity(surfaceID: String) {
            let scanned = Set(records.values.lazy
                .filter { $0.surfaceID == surfaceID }
                .map(\.sessionID))
            #expect(index.sessionIDs(surfaceID: surfaceID) == scanned)
        }

        records["one"] = Record(sessionID: "one", surfaceID: "surface-a")
        index.update(sessionID: "one", previousSurfaceID: nil, currentSurfaceID: "surface-a")
        records["two"] = Record(sessionID: "two", surfaceID: "surface-a")
        index.update(sessionID: "two", previousSurfaceID: nil, currentSurfaceID: "surface-a")
        records["unbound"] = Record(sessionID: "unbound", surfaceID: nil)
        index.update(sessionID: "unbound", previousSurfaceID: nil, currentSurfaceID: nil)
        expectParity(surfaceID: "surface-a")

        records["one"]?.surfaceID = "surface-b"
        index.update(
            sessionID: "one",
            previousSurfaceID: "surface-a",
            currentSurfaceID: "surface-b"
        )
        expectParity(surfaceID: "surface-a")
        expectParity(surfaceID: "surface-b")

        let removed = records.removeValue(forKey: "two")
        index.update(
            sessionID: "two",
            previousSurfaceID: removed?.surfaceID,
            currentSurfaceID: nil
        )
        expectParity(surfaceID: "surface-a")
        expectParity(surfaceID: "surface-b")
    }

    @Test("an index miss scans authoritative records once and self-heals")
    func selfHealsFromAuthoritativeRecords() {
        let records = [
            "one": Record(sessionID: "one", surfaceID: "surface-a"),
            "two": Record(sessionID: "two", surfaceID: "surface-a"),
            "other": Record(sessionID: "other", surfaceID: "surface-b"),
        ]
        var index = ChatSessionSurfaceIndex<String>()

        let healed = index.sessionIDs(
            surfaceID: "surface-a",
            healingFrom: records,
            recordSurfaceID: \.surfaceID
        )

        #expect(healed == ["one", "two"])
        #expect(index.sessionIDs(surfaceID: "surface-a") == healed)
    }
}
