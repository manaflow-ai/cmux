import CmuxNextAgentIntegrations
import Foundation
import Testing

/// `cmux setup mcp` writes nothing: it reports whether each installed agent gets cmux's server when
/// cmux starts it (`terminals`) and the manual lines a person runs to use it elsewhere. Settings and
/// the onboarding step read it this way.
struct AgentToolsTerminalsTests {
    @Test func aTerminalsReportShowsItsAgentsAsGettingCmuxToolsInCmux() throws {
        let report = """
        {"scope": "terminals", "clients": [
          {"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals"},
          {"id": "codex", "name": "Codex", "installed": true, "state": "terminals"},
          {"id": "gemini", "name": "Gemini", "installed": false, "state": "not_applicable"}
        ]}
        """
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.state.rawValue) == ["terminals", "terminals"])
        #expect(agents.map(\.id) == ["claude", "codex"])
    }

    /// Only `terminals` gives the agent cmux's tools; before the person's yes an agent is ready.
    @Test func onlyTerminalsGivesTheAgentCmuxTools() throws {
        let report = #"{"clients": [{"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals"}, {"id": "codex", "name": "Codex", "installed": true, "state": "planned"}, {"id": "x", "name": "X", "installed": true, "state": "failed"}]}"#
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.state) == [.terminals, .ready, .failed])
        #expect(agents.map(\.state.givesTools) == [true, false, false])
    }

    /// The manual lines come through as the CLI wrote them; a report without them has none.
    @Test func theManualLinesAreRead() {
        let report = #"{"clients": [], "manual": {"text": "…", "commands": ["claude mcp add --scope user cmux -- /x/cmux mcp serve", "codex mcp add cmux -- /x/cmux mcp serve"]}}"#
        #expect(AgentToolsAgent.manualCommands(setupReport: Data(report.utf8)) == [
            "claude mcp add --scope user cmux -- /x/cmux mcp serve",
            "codex mcp add cmux -- /x/cmux mcp serve",
        ])
        #expect(AgentToolsAgent.manualCommands(setupReport: Data(#"{"clients": []}"#.utf8)).isEmpty)
    }

    /// A `cmux` entry an older cmux wrote into an agent's own config comes through with the exact
    /// line that removes it; none, no line.
    @Test func aLeftoverEntryCarriesItsRemoveLine() throws {
        let report = #"{"clients": [{"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals", "leftover": {"command": "/Applications/cmux.app/Contents/Resources/bin/cmux", "args": ["mcp", "serve"], "remove": "claude mcp remove --scope user cmux"}}, {"id": "codex", "name": "Codex", "installed": true, "state": "terminals", "leftover": null}]}"#
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents.map(\.leftover) == ["claude mcp remove --scope user cmux", nil])
    }

    /// Remove's result: gone (or none was there), kept with the CLI's reason (an entry with settings
    /// cmux could not put back; the card shows that text), or failed.
    @Test func removeSaysWhyItKeptAnEntry() {
        let kept = #"{"state": "needs_user", "user_action": {"kind": "keep", "text": "Claude Code's cmux entry has settings cmux would not put back (env API_TOKEN), so it is left as it is."}}"#
        #expect(AgentToolsRemoval(removeReport: Data(kept.utf8))
            == .kept("Claude Code's cmux entry has settings cmux would not put back (env API_TOKEN), so it is left as it is."))
        #expect(AgentToolsRemoval(removeReport: Data(#"{"state": "changed"}"#.utf8)) == .removed)
        #expect(AgentToolsRemoval(removeReport: Data(#"{"state": "ok"}"#.utf8)) == .removed)
        #expect(AgentToolsRemoval(removeReport: Data(#"{"state": "failed"}"#.utf8)) == .failed)
        #expect(AgentToolsRemoval(removeReport: Data("not json".utf8)) == .failed)
    }
}
