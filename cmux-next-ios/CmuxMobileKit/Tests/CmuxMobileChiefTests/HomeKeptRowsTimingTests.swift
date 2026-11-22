import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// conn-quiet timing (Leo, 2026-11-14: "load faster/percievably load faster"): a relaunch's Home,
/// from `showKeptRows` to the kept rows on the feed, with 200 rows kept (the cache's limit). The
/// same harness runs at the base and the head; it prints one `CONNQUIET {json}` line with p50 and
/// p95 in ms and how many runs had the rows in the same turn (the first frame). It asserts nothing
/// about time: it is the measurement, not a gate.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct HomeKeptRowsTimingTests {
    static func rows(_ count: Int) -> [MacHomeRow] {
        (0..<count).compactMap { index in
            MacHomeRow(wire: [
                "id": "row-\(index)", "kind": index % 6 == 0 ? "chief" : "direct", "name": "Conversation \(index)",
                "unread": index % 3, "activity_at": "2026-11-14T12:00:00Z",
                "preview": "**Done (#\(index)).** The dialer now retries with `backoff`, capped at 30 s. 24 tests pass.",
                "pinned": index < 4, "pin_position": index,
            ])
        }
    }

    @Test func keptRowsToTheFeedAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-kept-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-1")
        let writer = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        writer.save(key, rows: Self.rows(200))
        writer.flush()

        var samples: [Double] = []
        var sameTurn = 0
        let runs = 31
        for _ in 0..<runs {
            // A new run: nothing in memory.
            let cache = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
            let feed = MacHomeFeed(rowsCache: cache, accountID: { "user-a" })
            let start = ContinuousClock.now
            feed.showKeptRows(of: "mac-1")
            if feed.rows != nil { sameTurn += 1 }
            #expect(await eventually { feed.rows != nil })
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int((Double(samples.count) * 0.95).rounded(.up)) - 1)]
        let line = #"CONNQUIET {"metric":"home_kept_rows_after_relaunch","rows":200,"runs":\#(runs),"p50_ms":\#(p50),"p95_ms":\#(p95),"same_turn":\#(sameTurn)}"#
        print(line)
        // The step artifact keeps attachments, not print lines (its console log comes back empty).
        Attachment.record(line, named: "connquiet-home.txt")
    }
}
