import Foundation
import Testing
@testable import CmuxNextDaemon

/// `notification-source-v1`: the daemon names who posted each notification
/// on the event and the tab marker; the app passes its own source on `notify`.
@Suite(.timeLimit(.minutes(1))) struct NotificationSourceTests {
    @Test func eventAndTabMarkerCarryTheSource() throws {
        let line = Data(#"{"event":"notification","notification":7,"title":"nine","body":"","level":"info","surface":3,"source":"terminal"}"#.utf8)
        guard case .notification(let event) = DaemonEvent.decode(name: "notification", line: line) else {
            Issue.record("expected a notification event")
            return
        }
        #expect(event.source == "terminal")
        let tab = try JSONDecoder().decode(TabSnapshot.self, from: Data(
            #"{"surface":3,"kind":"pty","notification":{"notification":7,"unread":true,"level":"info","source":"agent"}}"#.utf8))
        #expect(tab.notification?.source == "agent")

        // Older daemons send neither.
        let old = Data(#"{"event":"notification","notification":8,"title":"t","body":"","level":"info","surface":null}"#.utf8)
        guard case .notification(let legacy) = DaemonEvent.decode(name: "notification", line: old) else {
            Issue.record("expected a notification event")
            return
        }
        #expect(legacy.source == nil)
    }

    static func server(_ log: PlacementTests.Log, sources: Bool) throws -> FakeDaemonServer {
        let identify = ConnectionTests.identify.replacingOccurrences(
            of: #""attach-initial-size""#,
            with: #""attach-initial-size""# + (sources ? #","notification-source-v1""# : ""))
        return try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default:
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{"notification":5}}"#]
            }
        })
    }

    @Test func notifySendsItsSourceOnlyToDaemonsThatServeIt() async throws {
        for sources in [true, false] {
            let log = PlacementTests.Log()
            let server = try Self.server(log, sources: sources)
            defer { server.stop() }
            let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
            try await connection.start()
            let id = try await connection.notify(title: "done", source: "agent")
            #expect(id.rawValue == 5)
            let request = try #require(log.all.first)
            #expect(request["cmd"]?.stringValue == "notify")
            #expect(request["source"]?.stringValue == (sources ? "agent" : nil), "sources: \(sources)")
            await connection.close()
        }
    }
}
