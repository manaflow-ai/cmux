import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-reap-v1` client surface: `keep` on creation, `set-terminal-keep`,
/// `shutdown-daemon end_terminals`, and `terminal.project` over the resource
/// API on the same socket.
@Suite(.timeLimit(.minutes(1))) struct TerminalLifetimeTests {
    static func server(identify: String, _ log: PlacementTests.Log) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: { request in
            if request["protocol"]?.stringValue == "cmux.protocol/2" {
                log.append(request)
                let id = request["id"]?.stringValue ?? ""
                if case .string(let terminal)? = PlacementTests.object(request["params"])?["terminal"], terminal == "term_gone" {
                    return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":false,"error":{"code":"selector.not_found","message":"terminal not found","details":{},"retryable":false}}"#]
                }
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"generation":"GEN","revision":"7","replayed":false,"value":{"id":"tab_new","pane_id":"pane_p","index":2,"content_id":"term_t","content_kind":"terminal","focused":false,"name":null}}}"#]
            }
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "new-tab", "create-terminal":
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{"surface":41,"terminal_id":"\#(request["terminal_id"]?.stringValue ?? "t")","key":"k","lifecycle":"running","replayed":false}}"#]
            case "set-terminal-keep":
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{"terminal_id":"abc","keep":\#(request["keep"] == .bool(true))}}"#]
            case "shutdown-daemon":
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{"accepted":true,"pid":1,"generation":"GEN","ended_terminals":3}}"#]
            default:
                return [#"{"id":\#(id),"ok":false,"error":"unexpected"}"#]
            }
        })
    }

    static func connect(_ server: FakeDaemonServer) async throws -> DaemonConnection {
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: .init(terminalEnvironment: nil))
        try await connection.start()
        return connection
    }

    @Test func keepIsSentOnlyToReapingDaemons() async throws {
        for (identify, expectKeep) in [(PlacementEnvTests.identify, true), (PlacementTests.identify, false)] {
            let log = PlacementTests.Log()
            let server = try Self.server(identify: identify, log)
            defer { server.stop() }
            let connection = try await Self.connect(server)
            _ = try await connection.newTab(in: nil, options: SpawnOptions(keep: true))
            _ = try await connection.createTerminal(in: PlacementTests.key, keep: true)
            let sent = log.all
            #expect(sent.count == 2)
            for request in sent { #expect((request["keep"] == .bool(true)) == expectKeep) }
            await connection.close()
        }
    }

    /// The first terminal of a workspace also names itself in `env`.
    @Test func createTerminalNamesItsTerminalInEnv() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(identify: PlacementEnvTests.identify, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        _ = try await connection.createTerminal(in: PlacementTests.key)
        let request = try #require(log.all.first)
        let terminal = try #require(request["terminal_id"]?.stringValue)
        let env = try #require(PlacementTests.object(request["env"]))
        #expect(env["CMUX_SURFACE_ID"]?.stringValue == DaemonConnection.uuidForm(terminal))
        #expect(env["CMUX_WORKSPACE_ID"]?.stringValue == DaemonConnection.uuidForm(PlacementTests.key.rawValue))
        await connection.close()
    }

    @Test func setTerminalKeepNamesExactlyOneTarget() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(identify: PlacementEnvTests.identify, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        let reply = try await connection.setTerminalKeep(.surface(SurfaceID(rawValue: 9)), keep: true)
        #expect(reply.keep)
        _ = try await connection.setTerminalKeep(.terminal(TerminalID(rawValue: "abc")), keep: false)
        let sent = log.all
        #expect(sent[0]["surface"]?.intValue == 9 && sent[0]["terminal_id"] == nil && sent[0]["keep"] == .bool(true))
        #expect(sent[1]["terminal_id"]?.stringValue == "abc" && sent[1]["surface"] == nil && sent[1]["keep"] == .bool(false))
        await connection.close()
    }

    @Test func keepNeedsTheReapCapability() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(identify: PlacementTests.identify, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        await #expect(throws: DaemonError.self) { try await connection.setTerminalKeep(.surface(SurfaceID(rawValue: 1)), keep: true) }
        await #expect(throws: DaemonError.self) { try await connection.shutdownDaemon(endTerminals: true) }
        #expect(log.all.isEmpty)
        await connection.close()
    }

    @Test func shutdownCanEndEveryTerminal() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(identify: PlacementEnvTests.identify, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        let reply = try await connection.shutdownDaemon(endTerminals: true)
        #expect(reply.endedTerminals == 3)
        #expect(log.all.first?["end_terminals"] == .bool(true))
        await connection.close()
    }

    @Test func projectTerminalSpeaksTheResourceProtocol() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(identify: PlacementEnvTests.identify, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        let path = PaneResourcePath(workspace: ResourceID(rawValue: "ws_w"), screen: ResourceID(rawValue: "screen_s"),
                                    pane: ResourceID(rawValue: "pane_p"))
        let tab = try await connection.projectTerminal(ResourceID(rawValue: "term_t"), into: path, index: 2)
        #expect(tab.id == ResourceID(rawValue: "tab_new"))
        let request = try #require(log.all.first)
        #expect(request["operation"]?.stringValue == "terminal.project")
        #expect(request["type"]?.stringValue == "request")
        #expect(request["idempotency_key"]?.stringValue?.isEmpty == false)
        let params = try #require(PlacementTests.object(request["params"]))
        #expect(params["machine"]?.stringValue == "current" && params["session"]?.stringValue == "current")
        #expect(params["terminal"]?.stringValue == "term_t")
        #expect(params["destination_workspace"]?.stringValue == "ws_w")
        #expect(params["destination_screen"]?.stringValue == "screen_s")
        #expect(params["destination_pane"]?.stringValue == "pane_p")
        #expect(params["index"]?.intValue == 2)
        // A structured resource error fails the request with its code.
        await #expect {
            try await connection.projectTerminal(ResourceID(rawValue: "term_gone"), into: path, index: 0)
        } throws: { error in
            if case DaemonError.command(_, _, let code) = error { return code == "selector.not_found" }
            return false
        }
        await connection.close()
    }
}
