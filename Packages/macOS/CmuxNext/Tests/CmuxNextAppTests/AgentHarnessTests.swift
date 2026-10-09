import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// BRING-YOUR-OWN-HARNESS (Lawrence 2026-10-08: "ensure people are able to add their own ACP
/// stuff, via UI, cli, mcp, cmd shift p"): one action path for the palette, the CLI and MCP, and
/// the request the daemon gets from each.
@MainActor
@Suite struct AgentHarnessTests {
    @Test func everyHarnessActionIsInThePaletteAndTheMutationsAreCLIAndMCPVerbs() throws {
        let actions = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id.rawValue, $0) })
        for (id, verb) in [("agent.harness.add", "agent harness add"), ("agent.harness.remove", "agent harness remove"),
                           ("agent.harness.restore", "agent harness restore"), ("agent.harness.doctor", "agent harness doctor")] {
            let action = try #require(actions[id])
            #expect(action.cliName == verb)
            #expect(action.surfacePlan.mcp?.isOffered == true)
        }
        #expect(actions["agent.harness.addFromRegistry"]?.surfaces.contains(.palette) == true)
        #expect(actions["palette.addHarness"]?.title == "Integrate a Harness with an Agent…")
    }

    @Test func argsAndKeychainEnvGoOnlyWithACommandAndNeverCarryAValue() {
        var request = AgentHarnessAddRequest(command: "/opt/acme/bin/acme", args: ["acp"], envKeys: ["ACME_TOKEN"])
        #expect(request.params["args"] as? [String] == ["acp"])
        #expect(request.params["env"] as? [String: String] == ["ACME_TOKEN": "keychain:ACME_TOKEN"])
        request = AgentHarnessAddRequest(args: ["acp"], registry: "goose", envKeys: ["ACME_TOKEN"])
        #expect(request.params["registry"] as? String == "goose")
        #expect(request.params["args"] == nil)
        #expect(request.params["env"] == nil)
        #expect(!AgentHarnessAddRequest(displayName: "Acme").isComplete)
    }

    @Test func typedArgumentsSplitOnSpacesAndKeepQuotedWords() {
        #expect(AgentHarnessAddRequest.words(#"acp --mode "fast lane" ''"#) == ["acp", "--mode", "fast lane", ""])
        #expect(AgentHarnessAddRequest.words("  ").isEmpty)
    }

    @Test func rowsNameWhereEachHarnessCameFromAndOnlyUserFilesAreRemovable() {
        let list: JSONValue = [
            "defaultHarness": "claude",
            "harnesses": [
                "claude": ["kind": "claude-stdio", "description": "found on PATH"],
                "acme": ["kind": "acp", "source": "user-file", "sourcePath": "/u/acme.toml", "displayName": "Acme", "probeError": "timed out"],
                "corp": ["kind": "acp", "source": "managed"],
                "old": ["kind": "acp", "description": "imported from ~/.acpx"],
            ],
        ]
        let rows = Dictionary(uniqueKeysWithValues: AgentHarnessRows.rows(list).map { ($0["id"]?.stringValue ?? "", $0) })
        #expect(rows["claude"]?["source"] == "builtIn")
        #expect(rows["claude"]?["default"] == true)
        #expect(rows["acme"]?["source"] == "user")
        #expect(rows["acme"]?["removable"] == true)
        #expect(rows["acme"]?["name"] == "Acme")
        #expect(rows["acme"]?["probeError"] == "timed out")
        #expect(rows["corp"]?["removable"] == false)
        #expect(rows["old"]?["source"] == "acpx")
        // Never the command line or env.
        #expect(rows.values.allSatisfy { $0["argv"] == nil && $0["env"] == nil })
    }

    @Test func aDaemonRefusalNamesItsReasonForThePage() {
        #expect(AgentHarnessCenter.code(AcpmuxRPCError(name: "harness.exists", message: "acme already has a profile")) == "exists")
        #expect(AgentHarnessCenter.code(AgentHarnessFailure.unsupported) == "unsupported")
        #expect(AgentHarnessCenter.code(AgentHarnessFailure.noDaemon) == "unavailable")
    }
}
