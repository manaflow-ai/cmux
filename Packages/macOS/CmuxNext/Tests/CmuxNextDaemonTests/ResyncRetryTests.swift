import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// A snapshot that fails (the daemon was busy past the deadline) must be
/// retried on its own: before, the store stayed stale until an unrelated
/// event happened to need another resync, and CLI cleanup then missed tabs
/// the daemon had created meanwhile (leaked terminal hosts in the storm bench).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ResyncRetryTests {
    @Test func aFailedSnapshotIsRetriedWithoutAnotherEvent() async throws {
        let tree = String(decoding: try Fixture.data("list-workspaces.json"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshots = Mutex(0)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            switch request["cmd"]?.stringValue {
            case "list-workspaces":
                let attempt = snapshots.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard attempt > 1 else {
                    return [#"{"id":\#(id),"ok":false,"error":{"code":"busy","message":"busy"}}"#]
                }
                return [tree.replacingOccurrences(of: #"{"id":0,"#, with: #"{"id":\#(id),"#)]
            case "list-agents":
                return [#"{"id":\#(id),"ok":true,"data":{"agents":[]}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        let store = DaemonStore()
        _ = try await connection.start()
        let run = Task { await store.run(connection: connection) }
        defer { run.cancel() }
        try await store.waitUntil("snapshot applied after a failed first attempt") { store.isLoaded }
        #expect(snapshots.withLock { $0 } >= 2)
        #expect(store.workspaces.map(\.name).contains("beta"))
        await connection.close()
    }
}
