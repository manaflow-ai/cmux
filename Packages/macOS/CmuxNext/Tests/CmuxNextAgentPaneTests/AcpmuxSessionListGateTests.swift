import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `_acpmux/sessions` fields a capability serves (`pendingOnly`: `session-list-pending-v1`;
/// `localOnly`, `excludeStatus`, `orderBy`: `session-list-filters-v1`). An older acpmux ignores
/// a param it does not know and answers the whole list, never an error: sent unchecked, a filter
/// reads every peer's sessions and the caller takes them for the narrowed list. Every sender
/// goes through ``AcpmuxSessionListGate``.
@MainActor
struct AcpmuxSessionListGateTests {
    /// An acpmux that serves `_acpmux/sessions` the way it did before the filters: it ignores
    /// every param but `limit` and `cursor`, and pages `rows` by their place in the list.
    final class OldAcpmux {
        let rows: [[String: Any]]
        private(set) var sent: [[String: Any]] = []
        private(set) var rowsRead = 0
        init(rows: [[String: Any]]) { self.rows = rows }

        func call(_ method: String, _ params: [String: Any]) -> [String: Any]? {
            guard method == "_acpmux/sessions" else { return nil }
            sent.append(params)
            let start = (params["cursor"] as? String).flatMap { Int($0.dropFirst(2)) } ?? 0
            let end = (params["limit"] as? Int).map { min(start + $0, rows.count) } ?? rows.count
            rowsRead += end - start
            var page: [String: Any] = ["sessions": Array(rows[start..<end])]
            if params["limit"] != nil { page["nextCursor"] = end < rows.count ? "c:\(end)" : NSNull() }
            return page
        }
    }

    /// 10,000 peer sessions, every 1,000th with an ask, and one of this Mac's own with one.
    static func fleet() -> [[String: Any]] {
        var rows: [[String: Any]] = (0..<10_000).map { n in
            ["sessionId": "acp_peer_\(n)", "peer": "peer-mac", "status": "idle",
             "pendingPermissions": n % 1_000 == 0 ? 1 : 0]
        }
        rows.append(["sessionId": "acp_own", "status": "waiting", "pendingPermissions": 2])
        return rows
    }

    @Test func anAcpmuxWithoutPendingOnlyIsPagedWholeAndSentNoPendingOnly() async throws {
        let old = OldAcpmux(rows: Self.fleet())
        let rows = try #require(await AcpmuxSessionListGate(capabilities: ["acpmux-v1"]).pendingSessions { old.call($0, $1) })
        #expect(old.sent.allSatisfy { $0["pendingOnly"] == nil })
        #expect(old.sent.allSatisfy { $0["limit"] as? Int == 64 })
        #expect(old.sent.count == (10_001 + 63) / 64, "every page, each from the last one's cursor")
        #expect(old.rowsRead == 10_001)
        #expect(rows.compactMap { $0["sessionId"] as? String }.sorted()
            == (["acp_own"] + (0..<10).map { "acp_peer_\($0 * 1_000)" }).sorted())
    }

    @Test func anAcpmuxWithPendingOnlyIsAskedOnceForTheChatsWithAnAsk() async throws {
        var sent: [[String: Any]] = []
        let rows = try #require(await AcpmuxSessionListGate(
            capabilities: ["acpmux-v1", AcpmuxSessionListGate.pendingCapability]).pendingSessions { method, params in
                #expect(method == "_acpmux/sessions")
                sent.append(params)
                return ["sessions": [["sessionId": "acp_own", "pendingPermissions": 1]]]
            })
        #expect(sent.count == 1)
        #expect(sent.first?["pendingOnly"] as? Bool == true)
        #expect(sent.first?["limit"] == nil)
        #expect(rows.count == 1)
    }

    /// More chats with an ask than one reply holds (past 1 MiB) come in pages: each `nextCursor`
    /// is read with `pendingOnly` again, and every page's chats are kept.
    @Test func pendingOnlyPagesAreFollowedToTheLast() async throws {
        var sent: [[String: Any]] = []
        let rows = try #require(await AcpmuxSessionListGate(
            capabilities: [AcpmuxSessionListGate.pendingCapability]).pendingSessions { _, params in
                sent.append(params)
                switch params["cursor"] as? String {
                case nil: return ["sessions": [["sessionId": "a", "pendingPermissions": 1]], "nextCursor": "c1"]
                case "c1": return ["sessions": [["sessionId": "b", "pendingPermissions": 1]], "nextCursor": "c2"]
                default: return ["sessions": [["sessionId": "c", "pendingPermissions": 1]]]
                }
            })
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0["pendingOnly"] as? Bool == true && $0["limit"] == nil })
        #expect(rows.compactMap { $0["sessionId"] as? String } == ["a", "b", "c"])
    }

    @Test func aFailedPageIsNoList() async {
        let rows = await AcpmuxSessionListGate(capabilities: []).pendingSessions { _, _ in nil }
        #expect(rows == nil)
    }

    @Test func theCapabilitiesAreReadFromInitialize() {
        let result: [String: Any] = ["_meta": ["acpmux": ["capabilities": ["acpmux-v1", "session-list-pending-v1"]]]]
        #expect(AcpmuxSessionListGate(initialize: result).capabilities == ["acpmux-v1", "session-list-pending-v1"])
        #expect(AcpmuxSessionListGate(initialize: ["protocolVersion": 1]).capabilities.isEmpty)
        #expect(AcpmuxSessionListGate(initialize: nil).capabilities.isEmpty)
    }

    /// The quit census still sends its filters, and only to an acpmux that serves them.
    @Test func theCensusFiltersNeedTheFiltersCapability() {
        let census = AcpmuxSessionListGate.localLiveCensus
        #expect(census["localOnly"] as? Bool == true)
        #expect(census["excludeStatus"] as? [String] == ["closed"])
        #expect(census["orderBy"] as? String == "sessionId")
        #expect(AcpmuxSessionListGate.requiredCapability(fields: census.keys) == AcpmuxSessionListGate.filtersCapability)
        #expect(AcpmuxSessionListGate.requiredCapability(fields: ["pendingOnly"]) == AcpmuxSessionListGate.pendingCapability)
        #expect(AcpmuxSessionListGate.requiredCapability(fields: ["limit", "cursor", "usage"]) == nil)
    }

    /// The detector: a gated field's name as a request key (`"localOnly":`, `["localOnly"] =`)
    /// anywhere in CmuxNext's sources but the gate is a request built past its capability check.
    @Test func noGatedSessionListFieldIsSentOutsideTheGate() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let fields = ["localOnly", "excludeStatus", "orderBy", "pendingOnly"]
        let key = try Regex("\"(\(fields.joined(separator: "|")))\"\\s*:|\\[\"(\(fields.joined(separator: "|")))\"\\]\\s*=")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        var found: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            guard file.lastPathComponent != "AcpmuxSessionListGate.swift" else { continue }
            read += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(key) {
                found.append("\(file.path.replacingOccurrences(of: sources.path + "/", with: "")):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(read > 100, "CmuxNext's sources were read")
        #expect(found.isEmpty, "a gated _acpmux/sessions field sent without the capability check; build it with AcpmuxSessionListGate:\n\(found.joined(separator: "\n"))")
    }
}
