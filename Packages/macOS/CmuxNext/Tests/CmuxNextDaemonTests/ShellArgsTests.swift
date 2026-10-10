import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-shell-args-v1`: every terminal-creating command carries the
/// shell arguments Ghostty's integration needs for the shell in its `env`
/// (bash `--posix`, nushell `--execute`), and none against older daemons.
@Suite(.timeLimit(.minutes(1))) struct ShellArgsTests {
    static let bashEnv = [
        "SHELL": "/opt/homebrew/bin/bash",
        "ENV": "/App/Contents/Resources/ghostty/shell-integration/bash/ghostty.bash",
        "GHOSTTY_BASH_INJECT": "1",
    ]

    static func identify(shellArgs: Bool) -> String {
        let capabilities = #""attach-initial-size","terminal-env-v1","terminal-placement-env-v1""#
            + (shellArgs ? #","terminal-shell-args-v1""# : "")
        return ConnectionTests.identify.replacingOccurrences(of: #""attach-initial-size""#, with: capabilities)
    }

    static func server(_ log: PlacementTests.Log, shellArgs: Bool) throws -> FakeDaemonServer {
        let identify = identify(shellArgs: shellArgs)
        return try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "create-terminal":
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{"surface":41,"terminal_id":"0b6c4a526d3f4c559d538f1f4e0f1a31","key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a31","lifecycle":"running","replayed":false}}"#]
            default:
                log.append(request)
                let terminal = request["terminal_id"]?.stringValue ?? ""
                return [#"{"id":\#(id),"ok":true,"data":{"surface":41,"terminal_id":"\#(terminal)"}}"#]
            }
        })
    }

    static func connect(_ server: FakeDaemonServer, env: [String: String]) async throws -> DaemonConnection {
        let connection = DaemonConnection(
            endpoint: DaemonEndpoint(socketPath: server.path),
            configuration: .init(terminalEnvironment: { env }))
        try await connection.start()
        return connection
    }

    static func shellArgs(_ request: [String: JSONValue]) -> [String]? {
        guard case .array(let values)? = request["shell_args"] else { return nil }
        return values.compactMap(\.stringValue)
    }

    @Test func everySpawnCommandCarriesTheIntegrationArguments() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log, shellArgs: true)
        defer { server.stop() }
        let connection = try await Self.connect(server, env: Self.bashEnv)
        let pane = PaneID(rawValue: 3)
        _ = try await connection.newTab(in: pane, options: SpawnOptions(workspace: PlacementTests.key))
        _ = try await connection.split(pane, direction: .right, options: SpawnOptions(workspace: PlacementTests.key))
        _ = try await connection.newPaneInColumn(of: pane, options: SpawnOptions(workspace: PlacementTests.key))
        _ = try await connection.newColumn(rightOf: pane, options: SpawnOptions(workspace: PlacementTests.key))
        _ = try await connection.createTerminal(in: PlacementTests.key)
        let requests = log.all
        #expect(requests.map { $0["cmd"]?.stringValue ?? "" } == ["new-tab", "split", "new-pane", "new-pane-right", "create-terminal"])
        for request in requests {
            #expect(Self.shellArgs(request) == ["--posix"], "\(request["cmd"]?.stringValue ?? "")")
        }
        await connection.close()
    }

    @Test func aChosenProgramOrAnotherShellGetsNoArguments() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log, shellArgs: true)
        defer { server.stop() }
        let connection = try await Self.connect(server, env: Self.bashEnv)
        _ = try await connection.createTerminal(in: PlacementTests.key, argv: ["/usr/bin/top"])
        _ = try await connection.newTab(in: nil, options: SpawnOptions(env: ["SHELL": "/bin/zsh"], workspace: PlacementTests.key))
        for request in log.all {
            #expect(request["shell_args"] == nil, "\(request)")
        }
        await connection.close()
    }

    @Test func olderDaemonsGetNoArguments() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log, shellArgs: false)
        defer { server.stop() }
        let connection = try await Self.connect(server, env: Self.bashEnv)
        _ = try await connection.newTab(in: nil, options: SpawnOptions(workspace: PlacementTests.key))
        #expect(log.all.first?["shell_args"] == nil)
        await connection.close()
    }
}
