import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-placement-env-v1`: new tabs, splits, column panes, and columns
/// are one command carrying a client-chosen `terminal_id` that `env` names,
/// so the tab appears only in its target pane (no create-terminal, no move).
@Suite(.timeLimit(.minutes(1))) struct PlacementEnvTests {
    static let identify = ConnectionTests.identify.replacingOccurrences(
        of: #""attach-initial-size""#,
        with: #""attach-initial-size","terminal-env-v1","terminal-placement-env-v1","terminal-reap-v1""#)
    static let key = PlacementTests.key

    /// Answers every spawn command with surface 41 and the requested id.
    static func server(_ log: PlacementTests.Log) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "new-tab", "split", "new-pane", "new-pane-right":
                log.append(request)
                let terminal = request["terminal_id"]?.stringValue ?? ""
                return [#"{"id":\#(id),"ok":true,"data":{"surface":41,"terminal_id":"\#(terminal)","terminal_incarnation":"i1"}}"#]
            default:
                log.append(request)
                return [#"{"id":\#(id),"ok":false,"error":"unexpected \#(request["cmd"]?.stringValue ?? "")"}"#]
            }
        })
    }

    static func connect(_ server: FakeDaemonServer) async throws -> DaemonConnection {
        let connection = DaemonConnection(
            endpoint: DaemonEndpoint(socketPath: server.path),
            configuration: .init(terminalEnvironment: { ["CMUX_TAG": "nx", "CMUX_SOCKET_PATH": "/tmp/cmux-debug-nx.sock", "PATH": "/usr/bin"] }))
        try await connection.start()
        return connection
    }

    /// The one request sent, its `terminal_id`, and its `env`.
    static func single(_ log: PlacementTests.Log, _ command: String) throws -> (request: [String: JSONValue], terminal: String, env: [String: JSONValue]) {
        let requests = log.all
        #expect(requests.count == 1, "expected one \(command), got \(requests.map { $0["cmd"]?.stringValue ?? "?" })")
        let request = try #require(requests.first)
        #expect(request["cmd"]?.stringValue == command)
        let terminal = try #require(request["terminal_id"]?.stringValue)
        // Lowercase UUIDv4 in 32 hex digits (the daemon rejects anything else).
        #expect(terminal.count == 32 && terminal == terminal.lowercased() && terminal.allSatisfy(\.isHexDigit))
        #expect(Array(terminal)[12] == "4")
        let env = try #require(PlacementTests.object(request["env"]))
        #expect(env["CMUX_SURFACE_ID"]?.stringValue == DaemonConnection.uuidForm(terminal))
        #expect(env["CMUX_PANEL_ID"] == env["CMUX_SURFACE_ID"])
        #expect(env["CMUX_TAG"]?.stringValue == "nx")
        #expect(env["CMUX_SOCKET_PATH"]?.stringValue == "/tmp/cmux-debug-nx.sock")
        return (request, terminal, env)
    }

    @Test func newTabIsOneCommandNamingItsTerminal() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: SpawnOptions(cwd: "/tmp", workspace: Self.key))
        let (request, terminal, env) = try Self.single(log, "new-tab")
        #expect(request["pane"]?.intValue == 3)
        #expect(request["cwd"]?.stringValue == "/tmp")
        #expect(env["CMUX_WORKSPACE_ID"]?.stringValue == "0B6C4A52-6D3F-4C55-9D53-8F1F4E0F1A31")
        #expect(created.surface == SurfaceID(rawValue: 41))
        #expect(created.terminalID?.rawValue == terminal)
        await connection.close()
    }

    @Test func splitIsOneCommandNamingItsTerminal() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        _ = try await connection.split(PaneID(rawValue: 5), direction: .down, options: SpawnOptions(cwd: "/var", workspace: Self.key))
        let (request, _, env) = try Self.single(log, "split")
        #expect(request["dir"]?.stringValue == "down")
        #expect(request["cwd"]?.stringValue == "/var")
        #expect(env["CMUX_WORKSPACE_ID"] != nil)
        await connection.close()
    }

    @Test func newPaneInColumnCarriesEnvAndCwd() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        _ = try await connection.newPaneInColumn(of: PaneID(rawValue: 7), options: SpawnOptions(cwd: "/opt", workspace: Self.key))
        let (request, _, env) = try Self.single(log, "new-pane")
        #expect(request["cwd"]?.stringValue == "/opt")
        #expect(env["CMUX_WORKSPACE_ID"] != nil)
        await connection.close()
    }

    @Test func newColumnCarriesEnvAndCwd() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        _ = try await connection.newColumn(rightOf: PaneID(rawValue: 7), width: 0.5, options: SpawnOptions(cwd: "/usr", workspace: Self.key))
        let (request, _, _) = try Self.single(log, "new-pane-right")
        #expect(request["cwd"]?.stringValue == "/usr")
        #expect(request["width"] == .number(0.5))
        await connection.close()
    }

    /// Each spawn picks a fresh id, so two tabs never collide.
    @Test func everySpawnPicksAFreshTerminalID() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        _ = try await connection.newTab(in: nil, options: SpawnOptions(workspace: Self.key))
        _ = try await connection.newTab(in: nil, options: SpawnOptions(workspace: Self.key))
        let ids = log.all.compactMap { $0["terminal_id"]?.stringValue }
        #expect(ids.count == 2 && Set(ids).count == 2)
        await connection.close()
    }
}
