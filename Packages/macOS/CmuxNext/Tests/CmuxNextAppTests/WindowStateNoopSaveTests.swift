import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

/// Browser perf phase 2 (cx-asb1): `cmux tab <id> focus` on the tab that
/// already shows took 24 ms, because every selection or focus action writes
/// the window records into the daemon (a durable, fsynced projection put)
/// and `action.run` waits for that write. A save that changes nothing must
/// not reach the daemon.
@Suite(.serialized)
struct WindowStateNoopSaveTests {
    final class Puts: Sendable {
        let count = Mutex(0)
    }

    nonisolated static func daemon(_ puts: Puts) -> @Sendable ([String: JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = DaemonCapabilities.shared.required.map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "get-frontend-projection":
                return [#"{"id":\#(id),"ok":true,"data":{"frontend":"cmux-next","scope":"personal","subject_key":"windows","schema_version":1,"projection_revision":0,"projection":null}}"#]
            case "put-frontend-projection":
                let revision = puts.count.withLock { count -> Int in
                    count += 1
                    return count
                }
                return [#"{"id":\#(id),"ok":true,"data":{"frontend":"cmux-next","scope":"personal","subject_key":"windows","schema_version":1,"projection_revision":\#(revision),"projection":null}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    @Test func aSaveThatChangesNothingSendsNoWrite() async throws {
        let puts = Puts()
        let server = try ScriptedDaemonSocket(handler: Self.daemon(puts))
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        _ = try await connection.start()
        let store = WindowStateStore(connection: connection)
        try await store.load()
        let record = WindowRecord(id: "w1", frame: WindowFrame(x: 1, y: 2, width: 3, height: 4))
        try await store.update { $0.windows = [record] }
        #expect(puts.count.withLock { $0 } == 1, "a change is written")
        try await store.update { $0.windows = [record] }
        try await store.update { $0.windows = [record] }
        #expect(puts.count.withLock { $0 } == 1, "the same records again are not written")
        try await store.update { $0.windows = [record, WindowRecord(id: "w2")] }
        #expect(puts.count.withLock { $0 } == 2, "a later change is written")
        await connection.close()
    }
}
