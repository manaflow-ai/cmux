@testable import CmuxNextActions
import Testing

/// Live proof subp7: the Chief host's `agent.openSessionWorkspace {host: chief:<home id>}` was
/// refused ("has no argument 'host'"), so no subagent got a workspace while the app ran. The
/// action takes `host`, optional: the acpmux that runs the session.
struct AgentSessionWorkspaceArgumentTests {
    @Test func theOpenActionTakesAnOptionalHost() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "agent.openSessionWorkspace" })
        let host = try #require(action.arguments.first { $0.name == "host" })
        #expect(!host.isRequired)
        #expect(host.kind == .string)
    }
}
