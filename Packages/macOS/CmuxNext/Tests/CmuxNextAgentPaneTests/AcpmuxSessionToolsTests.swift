import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The session tools at the daemon spawn boundary (``AcpmuxDaemonLauncher``): with the Debug
/// Settings toggle `agent.sessionTools` on (the default) the daemon gets no `ACPMUX_SESSION_TOOLS`,
/// so acpmux gives every local session `start_session`, `list_sessions`, `read_session` and
/// `send_to_session`; off, it gets `ACPMUX_SESSION_TOOLS=0`. An inherited value never survives.
@Suite(.serialized)
struct AcpmuxSessionToolsTests {
    static func environment(sessionTools: Bool) throws -> AcpmuxEnvironment {
        var environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: nil,
            environment: ["ACPMUX_HOME": "/tmp/ast-home", "ACPMUX_SOCKET": "/tmp/ast-home/s.sock"],
            isExecutable: { _ in true }, executableOverride: URL(fileURLWithPath: "/bin/false")
        ))
        environment.sessionTools = sessionTools
        return environment
    }

    @Test func theToggleIsOnByDefault() {
        let store = TunableStore()
        store.register(AgentPaneTunables.all)
        store.activate(file: nil)
        #expect(AgentPaneTunables.sessionTools.value(in: store))
    }

    @Test func onTheDaemonKeepsTheSessionTools() throws {
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            try Self.environment(sessionTools: true), inherited: ["ACPMUX_SESSION_TOOLS": "0"])
        #expect(variables["ACPMUX_SESSION_TOOLS"] == nil)
    }

    @Test func offTheDaemonGetsTheSwitch() throws {
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(try Self.environment(sessionTools: false), inherited: [:])
        #expect(variables["ACPMUX_SESSION_TOOLS"] == "0")
    }
}
