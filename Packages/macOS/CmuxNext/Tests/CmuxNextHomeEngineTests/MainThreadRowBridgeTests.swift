import CmuxNextDaemon
@testable import CmuxNextHomeEngine
@testable import CmuxNextHomeModel
import Foundation
import Testing

/// The per-row rules calls of the Home list and sidebar (cmux#59531's class, 2026-11-27): a row
/// builder or a view's body asked a pure Rust rule (`HomeRules.call`) once per row per draw, each a
/// JSON encode, an FFI call and a decode on the main thread. Their answers are remembered by input
/// now; these tests hold the answers equal and time one list pass at 1,100 rows.
@Suite struct MainThreadRowBridgeTests {
    static let rowCount = 1_100

    @Test func rememberedBadgesAndTitlesAreTheRulesAnswers() {
        for harness in ["claude", "codex", "unii", "muse", "claude-cr", "nope", ""] {
            let first = ChiefBackend.badge(for: harness)
            #expect(ChiefBackend.badge(for: harness) == first)
            #expect(ChiefBackend.title(for: harness) == ChiefBackend.title(for: harness))
        }
        #expect(ChiefBackend.badge(for: nil) == ChiefBackend.badge(for: nil))
        #expect(ChiefBackend.title(for: "claude") == ChiefBackend.claude.title)
    }

    @Test func oneRowsRecordIsTheWholeListsAnswerForIt() throws {
        let rows = try Self.inboxRows(40)
        let all = HomeChiefNames.localRecords(rows)
        for row in rows {
            #expect(HomeChiefNames.localRecord(of: ConversationID(row.id), in: rows) == all[ConversationID(row.id)])
        }
        // A changed name answers anew, not from the old row's memory.
        var renamed = rows
        renamed[0].name = "Renamed Chief"
        #expect(HomeChiefNames.localRecord(of: ConversationID(renamed[0].id), in: renamed)
                    == HomeChiefNames.localRecords(renamed)[ConversationID(renamed[0].id)])
    }

    @Test func namesAnswerTheSameAskedAgainAndAfterARename() {
        var names = HomeChiefNames()
        let id = ConversationID("chief-1")
        let before = names.name(of: id, record: "Ada")
        #expect(names.name(of: id, record: "Ada") == before)
        names.rename(id, to: "Grace", record: "Ada")
        #expect(names.name(of: id, record: "Ada") == "Grace")
        #expect(names.all([id: "Ada"])[id] == "Grace")
        names.settle(id, record: "Grace")
        #expect(names.name(of: id, record: "Grace") == "Grace")
    }

    /// One Home list pass at 1,100 rows: each row's badge, backend title and registry name, the
    /// list's names and the Chief among the conversations, as the list build and the sidebar ask
    /// them on every draw. Prints the median of 7 passes (the PR's before/after number).
    @Test func aListPassAt1100RowsStaysFast() throws {
        let rows = try Self.inboxRows(Self.rowCount)
        let conversations = Self.conversations(Self.rowCount)
        let harnesses = ["claude", "codex", "unii", "muse", "claude-cr"]
        var names = HomeChiefNames()
        names.rename(ConversationID(rows[0].id), to: "Grace", record: nil)
        let records = Dictionary(uniqueKeysWithValues: rows.map { (ConversationID($0.id), $0.name) })

        func pass() -> Duration {
            ContinuousClock().measure {
                var seen = 0
                for (index, row) in rows.enumerated() {
                    let harness = harnesses[index % harnesses.count]
                    if ChiefBackend.badge(for: harness) != nil { seen += 1 }
                    seen += ChiefBackend.title(for: harness).count
                    if HomeChiefNames.localRecord(of: ConversationID(row.id), in: rows) != nil { seen += 1 }
                    if names.name(of: ConversationID(row.id), record: row.name) != nil { seen += 1 }
                }
                seen += names.all(records).count
                seen += HomeChiefNames.localRecords(rows).count
                for _ in 0..<4 { if HomeChiefName.select(from: conversations) != nil { seen += 1 } }
                #expect(seen > 0)
            }
        }
        _ = pass() // warm
        let samples = (0..<7).map { _ in pass() }.sorted()
        let median = samples[samples.count / 2]
        let ms = Double(median.components.seconds) * 1_000 + Double(median.components.attoseconds) / 1e15
        print("main-thread-row-bridge: list pass at \(Self.rowCount) rows median \(String(format: "%.2f", ms)) ms")
        // A 1,100-row pass is a frame's budget or less; the per-row rules calls made it seconds.
        #expect(ms < 250)
    }

    static func inboxRows(_ count: Int) throws -> [HomeInboxRequest.Row] {
        let rows: [[String: Any]] = (0..<count).map { index in
            ["id": "conv-\(index)", "kind": index % 3 == 0 ? "chief" : "dm", "name": "Chief \(index)",
             "unread": 0, "activityAt": "2026-11-27T00:00:00Z", "pinned": false, "markedUnread": false]
        }
        return try JSONDecoder().decode([HomeInboxRequest.Row].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    static func conversations(_ count: Int) -> [CmuxNextDaemon.ConversationSummary] {
        (0..<count).map { index in
            CmuxNextDaemon.ConversationSummary(id: "conv-\(index)", title: "Workspace \(index)", participants: [],
                                               lastSeq: 0, rev: 0, createdAt: "2026-11-\(10 + index % 17)T00:00:00Z",
                                               updatedAt: "2026-11-27T00:00:00Z")
        }
    }
}
