import Foundation
import Testing
@testable import CmuxNextDaemon

/// Reopen Closed Workspace: v2 `closed.list` (a read, no key) and
/// `closed.reopen` (a mutation with an idempotency key and the `closed` id).
@Suite(.timeLimit(.minutes(1))) struct ClosedHistoryTests {
    static let list = #"[{"id":"closed_t","kind":"tab","name":"logs","workspace_id":"ws_a","pane_id":"pane_p","index":1,"closed_at_ms":20,"screens":[]},{"id":"closed_w","kind":"workspace","name":"scratch","workspace_id":"ws_old","pane_id":null,"index":0,"closed_at_ms":10,"screens":[{"name":"s","tabs":[]}]}]"#
    static let reopened = #"{"generation":"GEN","revision":"4","replayed":false,"value":{"closed_id":"closed_w","kind":"workspace","workspace_id":"ws_new","screen_ids":["screen_1"],"tab_ids":["tab_1"]}}"#

    static func server(_ log: PlacementTests.Log) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: { request in
            if request["protocol"]?.stringValue == "cmux.protocol/2" {
                log.append(request)
                let id = request["id"]?.stringValue ?? ""
                let result = request["operation"]?.stringValue == "closed.list" ? Self.list : Self.reopened
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":\#(result)}"#]
            }
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(ConnectionTests.identify)}"#]
            default: return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
    }

    @Test func listsAndReopens() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let items = try await connection.closedItems()
        #expect(items == [
            .init(id: "closed_t", kind: .tab, name: "logs", workspaceID: "ws_a"),
            .init(id: "closed_w", kind: .workspace, name: "scratch", workspaceID: "ws_old"),
        ])
        let reopened = try await connection.reopenClosed("closed_w")
        #expect(reopened.workspaceID == "ws_new")
        #expect(reopened.tabIDs == ["tab_1"])

        let requests = log.all
        #expect(requests.map { $0["operation"]?.stringValue } == ["closed.list", "closed.reopen"])
        #expect(requests[0]["idempotency_key"] == nil)
        #expect(requests[1]["idempotency_key"]?.stringValue?.isEmpty == false)
        #expect(PlacementTests.object(requests[1]["params"])?["closed"]?.stringValue == "closed_w")
        await connection.close()
    }
}
