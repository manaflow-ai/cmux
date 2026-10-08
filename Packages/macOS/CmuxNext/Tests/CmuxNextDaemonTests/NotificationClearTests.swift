import Foundation
import Testing
@testable import CmuxNextDaemon

/// Clear All and the panel's Dismiss: v2 `notification.clear`, for every
/// notification or one terminal's, with an idempotency key.
@Suite(.timeLimit(.minutes(1))) struct NotificationClearTests {
    static func server(_ log: PlacementTests.Log) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: { request in
            if request["protocol"]?.stringValue == "cmux.protocol/2" {
                log.append(request)
                let id = request["id"]?.stringValue ?? ""
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"generation":"GEN","revision":"3","replayed":false,"value":{"cleared":["ntf_a","ntf_b"]}}}"#]
            }
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(ConnectionTests.identify)}"#]
            default: return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
    }

    @Test func clearAllAndOneTerminal() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        #expect(try await connection.clearNotifications() == ["ntf_a", "ntf_b"])
        _ = try await connection.clearNotifications(terminal: "term_t")
        let requests = log.all
        #expect(requests.count == 2)
        for request in requests {
            #expect(request["operation"]?.stringValue == "notification.clear")
            #expect(request["idempotency_key"]?.stringValue?.isEmpty == false)
        }
        #expect(PlacementTests.object(requests[0]["params"])?["terminal_id"] == nil)
        #expect(PlacementTests.object(requests[1]["params"])?["terminal_id"]?.stringValue == "term_t")
        #expect(requests[0]["idempotency_key"] != requests[1]["idempotency_key"])
        await connection.close()
    }
}
