import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// New tabs and splits reserve the terminal id so the shell gets
/// CMUX_WORKSPACE_ID and CMUX_SURFACE_ID naming itself.
@Suite(.timeLimit(.minutes(1))) struct PlacementTests {
    static let identify = ConnectionTests.identify.replacingOccurrences(of: #""attach-initial-size""#, with: #""attach-initial-size","terminal-env-v1""#)
    final class Log: Sendable {
        let entries = Mutex<[[String: JSONValue]]>([])
        func append(_ request: [String: JSONValue]) { entries.withLock { $0.append(request) } }
        var all: [[String: JSONValue]] { entries.withLock { $0 } }
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let members) = value { return members }
        return nil
    }

    static let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a31")

    /// Records create-terminal / move commands; create-terminal lands in pane 5.
    static func server(_ log: Log) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "create-terminal":
                log.append(request)
                let terminal = request["terminal_id"]?.stringValue ?? ""
                return [#"{"id":\#(id),"ok":true,"data":{"surface":40,"terminal_id":"\#(terminal)","pane":5,"screen":2,"workspace":1,"key":"\#(key.rawValue)","lifecycle":"running","replayed":false}}"#]
            case "move-tab", "move-tab-to-split":
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{"moved":true,"surface":40}}"#]
            default: return [#"{"id":\#(id),"ok":false,"error":"unexpected \#(request["cmd"]?.stringValue ?? "")"}"#]
            }
        })
    }

    @Test func newTabNamesItsOwnTerminalAndMovesIntoThePane() async throws {
        let log = Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path),
                                          configuration: .init(terminalEnvironment: { ["CMUX_TAG": "nx", "PATH": "/usr/bin"] }))
        try await connection.start()
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: SpawnOptions(cwd: "/tmp", workspace: Self.key))
        #expect(created.surface == SurfaceID(rawValue: 40))
        let requests = log.all
        let create = try #require(requests.first)
        let terminal = try #require(create["terminal_id"]?.stringValue)
        let env = try #require(Self.object(create["env"]))
        #expect(env["CMUX_WORKSPACE_ID"]?.stringValue == "0B6C4A52-6D3F-4C55-9D53-8F1F4E0F1A31")
        #expect(env["CMUX_SURFACE_ID"]?.stringValue == DaemonConnection.uuidForm(terminal))
        #expect(env["CMUX_PANEL_ID"] == env["CMUX_SURFACE_ID"])
        #expect(env["CMUX_TAG"]?.stringValue == "nx")
        #expect(create["cwd"]?.stringValue == "/tmp")
        #expect(requests.count == 2)
        #expect(requests.last?["cmd"]?.stringValue == "move-tab")
        #expect(requests.last?["pane"]?.intValue == 3)
        await connection.close()
    }

    @Test func splitMovesTheNewTerminalToASplit() async throws {
        let log = Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: .init(terminalEnvironment: nil))
        try await connection.start()
        _ = try await connection.split(PaneID(rawValue: 5), direction: .down, options: SpawnOptions(workspace: Self.key))
        let requests = log.all
        let env = try #require(Self.object(requests.first?["env"]))
        // A Cloud connection (no environment provider) still gets the placement keys.
        #expect(Set(env.keys) == ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID"])
        #expect(requests.last?["cmd"]?.stringValue == "move-tab-to-split")
        #expect(requests.last?["edge"]?.stringValue == "bottom")
        await connection.close()
    }
}
