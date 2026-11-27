import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import CmuxNextHomeModel
import Foundation
import Testing

/// What one Home pass costs the main thread to name its Chiefs, as `HomeService.chiefNames` and
/// `HomeService.chiefName(of:)` run it: the list's name map once, then the name of each visible row
/// (tiles, the chat header, the tab strip). Each name used to be a JSON encode, a `cmux_home_call`
/// and a decode, and the map sent every row to Rust, on every read.
/// Leo 2026-11-10: "lawrence was talkin bout how we wanted to fix the root cause of a lot of this main
/// thread stuff which was to borrow chrome's model". Slice 1 of that: a pass that changes nothing
/// crosses into Rust zero times, and costs the same at 1,000 rows as at 50 (within 4 times).
///
/// Prints `HOME-SIDEBAR-PASS-COST n=.. us=.. ffi=..` per size: the median microseconds of one pass
/// and the bridge calls per pass, after one warm-up pass.
@MainActor @Suite(.serialized) struct HomeChiefNamePassCostTests {
    static let sizes = [50, 200, 1000]
    static let passes = 50
    /// The rows a pass names one by one: the visible window, not the whole list.
    static let visible = 20

    static func rows(_ count: Int) throws -> [HomeInboxRequest.Row] {
        let rows: [[String: Any]] = (0..<count).map { index in
            [
                "id": "conv_\(index)", "kind": index % 4 == 0 ? "chief" : "direct",
                "name": index % 4 == 0 ? " Chief \(index) " : "Person \(index)",
                "unread": 0, "activity_at": "2026-11-27T00:00:00Z", "pinned": false, "marked_unread": false,
            ]
        }
        return try JSONDecoder().decode([HomeInboxRequest.Row].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    static let cloud = [
        HomeChiefRecord(id: "chief-cloud", name: "Hosted", isDefault: true, rev: 1, mainConversation: "conv_0"),
    ]

    static func microseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1000
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// One pass: the name map, then each visible row's name.
    static func pass(_ cache: HomeChiefNameCache, rows: [HomeInboxRequest.Row], renames: HomeChiefNames) {
        _ = cache.names(rows: rows, rowsRevision: 1, cloud: cloud, renames: renames)
        for row in rows.prefix(visible) {
            _ = cache.name(of: ConversationID(row.id), rows: rows, rowsRevision: 1, cloud: cloud, renames: renames)
        }
    }

    @Test func anUnchangedPassCrossesIntoRustZeroTimesAndStaysFlat() throws {
        var cost: [Int: Double] = [:]
        for count in Self.sizes {
            let rows = try Self.rows(count)
            let cache = HomeChiefNameCache()
            let renames = HomeChiefNames()
            Self.pass(cache, rows: rows, renames: renames)
            let before = HomeRules.callCount
            var times: [Double] = []
            for _ in 0..<Self.passes {
                times.append(Self.microseconds { Self.pass(cache, rows: rows, renames: renames) })
            }
            let ffi = Double(HomeRules.callCount - before) / Double(Self.passes)
            cost[count] = Self.median(times)
            print(String(format: "HOME-SIDEBAR-PASS-COST n=%d us=%.1f ffi=%.1f", count, cost[count]!, ffi))
            #expect(ffi == 0, "n=\(count): \(ffi) bridge calls per unchanged pass")
        }
        let small = try #require(cost[50]), large = try #require(cost[1000])
        #expect(large <= max(small, 1) * 4, "n=1000 \(large)us vs n=50 \(small)us")
    }

    /// The cache answers what the rules answer, and a new revision, registry or rename asks again.
    @Test func cachedNamesMatchTheRulesAndFollowEachInput() throws {
        let cache = HomeChiefNameCache()
        var rows = try Self.rows(8)
        let renames = HomeChiefNames()
        func uncached(_ rows: [HomeInboxRequest.Row], _ cloud: [HomeChiefRecord], _ renames: HomeChiefNames)
            -> [ConversationID: String] {
            var records = HomeChiefNames.localRecords(rows)
            for chief in cloud {
                guard let conversation = chief.mainConversation, let name = HomeChiefNames.trimmed(chief.name) else { continue }
                records[ConversationID(conversation)] = name
            }
            return renames.all(records)
        }
        #expect(cache.names(rows: rows, rowsRevision: 1, cloud: Self.cloud, renames: renames)
            == uncached(rows, Self.cloud, renames))
        #expect(cache.name(of: ConversationID("conv_0"), rows: rows, rowsRevision: 1, cloud: Self.cloud, renames: renames) == "Hosted")
        #expect(cache.name(of: ConversationID("conv_4"), rows: rows, rowsRevision: 1, cloud: Self.cloud, renames: renames) == "Chief 4")
        #expect(cache.name(of: ConversationID("conv_1"), rows: rows, rowsRevision: 1, cloud: Self.cloud, renames: renames) == nil)

        rows[4].name = "Renamed"
        #expect(cache.name(of: ConversationID("conv_4"), rows: rows, rowsRevision: 2, cloud: Self.cloud, renames: renames) == "Renamed")
        #expect(cache.names(rows: rows, rowsRevision: 2, cloud: Self.cloud, renames: renames)[ConversationID("conv_4")] == "Renamed")

        #expect(cache.name(of: ConversationID("conv_0"), rows: rows, rowsRevision: 2, cloud: [], renames: renames) == "Chief 0")

        var pending = renames
        pending.rename(ConversationID("conv_4"), to: "Pending", record: "Renamed")
        #expect(cache.name(of: ConversationID("conv_4"), rows: rows, rowsRevision: 2, cloud: [], renames: pending) == "Pending")
        #expect(cache.names(rows: rows, rowsRevision: 2, cloud: [], renames: pending) == uncached(rows, [], pending))
    }
}
