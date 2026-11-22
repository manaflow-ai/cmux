import Foundation
import Testing
@testable import CmuxNextDaemon

/// Decision K1: Cmd-K (Clear Screen and Scrollback) clears the terminal in the daemon, which owns
/// the terminal state (`clear-history`: the rows before the prompt and the retained history go,
/// every attached view gets the same erase). Clearing only the app's mirror is undone by the next
/// frame and comes back on reattach.
@Suite struct ClearHistoryRequestTests {
    @Test func clearHistorySendsTheSurfaceToTheDaemon() async throws {
        let log = Log()
        let server = try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(ConnectionTests.identify)}"#]
            case "clear-history":
                log.append(request["surface"]?.intValue ?? -1)
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default: return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        _ = try await connection.request(ClearHistoryRequest(surface: SurfaceID(rawValue: 41)))
        #expect(log.values == [41])
        await connection.close()
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        func append(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
