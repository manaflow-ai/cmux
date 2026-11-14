import CmuxNextAgentIntegrations
import Foundation
import Testing

/// A DEV build, or a build on its own settings file, never writes the person's global agent configs:
/// its `cmux setup mcp` is a dry run whose installed agents are `terminals` (they get cmux's server
/// in this build's terminals, through the shims). Settings and the onboarding step show them as
/// available there, never as "Not added".
struct AgentToolsTerminalsTests {
    @Test func aTerminalsReportShowsItsAgentsAsAvailableInCmuxTerminals() throws {
        let report = """
        {"scope": "terminals", "dry_run": true, "clients": [
          {"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals"},
          {"id": "codex", "name": "Codex", "installed": true, "state": "terminals"},
          {"id": "gemini", "name": "Gemini", "installed": false, "state": "not_applicable"}
        ]}
        """
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.state.rawValue) == ["terminals", "terminals"])
        #expect(agents.map(\.id) == ["claude", "codex"])
    }

    /// The person's yes is not "failed" in a DEV build: its agents have cmux's tools, in its terminals.
    @Test func terminalsAndAddedBothGiveTheAgentCmuxTools() throws {
        let report = #"{"clients": [{"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals"}, {"id": "codex", "name": "Codex", "installed": true, "state": "ok"}, {"id": "x", "name": "X", "installed": true, "state": "planned"}]}"#
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.state.givesTools) == [true, true, false])
    }

    /// A DEV build names an entry an older DEV build left (`stale_entry`): Settings says so and
    /// its Remove takes it out. No stale entry, no flag.
    @Test func aStaleDevEntryIsFlagged() throws {
        let report = #"{"scope": "terminals", "clients": [{"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals", "stale_entry": {"name": "cmux", "command": "/x/cmux DEV a.app/Contents/Resources/bin/cmux"}, "remove": "claude mcp remove --scope user cmux"}, {"id": "codex", "name": "Codex", "installed": true, "state": "terminals", "stale_entry": null}]}"#
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.stale) == [true, false])
    }

    /// An entry with settings cmux cannot put back is left alone: the agent shows as kept, not
    /// as ready to add.
    @Test func anEntryCmuxCannotPutBackShowsAsKept() throws {
        let report = #"{"state": "needs_user", "clients": [{"id": "claude", "name": "Claude Code", "installed": true, "state": "needs_user", "user_action": {"kind": "keep", "command": "claude mcp remove --scope user cmux && cmux setup mcp claude"}}]}"#
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.state.rawValue) == ["kept"])
    }
}
