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
}
