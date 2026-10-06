import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-frontend-shell-integration-v1` (R92 bug 2): only a connection
/// whose terminals get Ghostty's shell integration from this app (the local
/// daemon's `AppEnvironment.terminalEnvironmentProvider`) echoes it, so the
/// daemon starts their `SHELL` as given instead of integrating it again. A
/// connection without that environment (remote machines, the mobile compat
/// backend) keeps the daemon's own integration.
@Suite(.timeLimit(.minutes(1))) struct FrontendShellIntegrationTests {
    static let capability = "terminal-frontend-shell-integration-v1"

    static func echoed(_ configuration: DaemonConnectionConfiguration) async throws -> [String] {
        let log = PlacementTests.Log()
        let server = try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(ShellArgsTests.identify(shellArgs: true))}"#]
            case "set-client-info":
                log.append(request)
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default: return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: configuration)
        try await connection.start()
        await connection.close()
        guard case .array(let values)? = log.all.first?["capabilities"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    @Test func theLocalAppConnectionEchoesIt() async throws {
        let echoed = try await Self.echoed(.init(terminalEnvironment: { ["SHELL": "/bin/zsh"] }, resolvesShellIntegration: true))
        #expect(echoed.contains(Self.capability))
        #expect(echoed.filter { $0 == Self.capability }.count == 1)
    }

    @Test func otherConnectionsDoNot() async throws {
        #expect(try await !Self.echoed(.init(terminalEnvironment: { ["SHELL": "/bin/zsh"] })).contains(Self.capability))
        // Without an environment there is nothing the app resolved.
        #expect(try await !Self.echoed(.init(terminalEnvironment: nil, resolvesShellIntegration: true)).contains(Self.capability))
        #expect(!DaemonCapabilities.shared.advertised.contains(Self.capability))
    }

    /// `new-row` carries the argv-based integration like every other
    /// creating command; with the capability echoed the daemon starts
    /// exactly that, so a missing `--posix` would leave bash unintegrated.
    @Test func newRowCarriesTheIntegrationArguments() async throws {
        let log = PlacementTests.Log()
        let identify = ShellArgsTests.identify(shellArgs: true)
            .replacingOccurrences(of: #""terminal-shell-args-v1""#, with: #""terminal-shell-args-v1","rows-v1""#)
        let server = try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default:
                log.append(request)
                let terminal = request["terminal_id"]?.stringValue ?? ""
                return [#"{"id":\#(id),"ok":true,"data":{"surface":41,"terminal_id":"\#(terminal)"}}"#]
            }
        })
        defer { server.stop() }
        let connection = try await ShellArgsTests.connect(server, env: ShellArgsTests.bashEnv)
        _ = try await RowCommands(connection).newRow(below: PaneID(rawValue: 3), height: 400,
                                                     options: SpawnOptions(workspace: PlacementTests.key))
        let rows = log.all.filter { $0["cmd"]?.stringValue == "new-row" }
        #expect(rows.count == 1)
        #expect(rows.first.flatMap(ShellArgsTests.shellArgs) == ["--posix"])
        await connection.close()
    }

    /// `new-screen` carries the argv-based integration and the placement
    /// spawn fields, which the daemon applies with `screen-terminal-env-v1`.
    @Test func newScreenCarriesTheIntegrationArguments() async throws {
        let log = PlacementTests.Log()
        let server = try ShellArgsTests.server(log, shellArgs: true)
        defer { server.stop() }
        let connection = try await ShellArgsTests.connect(server, env: ShellArgsTests.bashEnv)
        _ = try await connection.newScreen(in: nil, spec: ScreenSpec(name: "s"),
                                           options: SpawnOptions(workspace: PlacementTests.key))
        let screens = log.all.filter { $0["cmd"]?.stringValue == "new-screen" }
        #expect(screens.count == 1)
        #expect(screens.first.flatMap(ShellArgsTests.shellArgs) == ["--posix"])
        #expect(screens.first?["terminal_id"]?.stringValue?.count == 32)
        await connection.close()
    }
}
