import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone's New Agent Chat mirrors the Mac's: one model-agnostic entry on the Mac's default
/// agent, every other agent listed with why a phone can't start it.
@Suite struct AgentCatalogTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// A `_acpmux/harnesses` reply shaped like acpmux's `harnesses_view` (harnesses keyed by id).
    var harnesses: String {
        """
        {"defaultHarness": "codex",
         "harnesses": {
           "codex": {"argv": ["codex-acp"], "family": "codex"},
           "claude": {"argv": ["claude-agent-acp"], "family": "claude", "start": {"model": "opus", "modelSource": "harness"}},
           "claude-cr": {"argv": ["claude-agent-acp"], "family": "claude", "displayName": "Claude (CodeRouter)"},
           "gemini": {"argv": ["gemini", "--acp"], "family": "gemini", "unavailable": "gemini is not installed"},
           "pi": {"argv": ["pi"], "family": "pi", "probeError": "probe timed out"},
           "muse": {"argv": ["muse"], "kind": "terminal"},
           "cmux": {"argv": ["claude"], "family": "claude", "kind": "claude-stdio", "pickerHidden": true}
         }}
        """
    }

    var models: String {
        """
        {"harnesses": [
          {"harness": "claude", "isDefault": false, "models": [
            {"id": "default", "name": "default (agent's choice)"},
            {"id": "opus", "name": "Opus"},
            {"id": "sonnet", "name": "Sonnet"},
            {"id": "haiku", "name": "Haiku", "unavailable": "your plan does not include this model"}]}
        ]}
        """
    }

    @Test func theMacsDefaultIsSkippedWhenAPhoneCantStartIt() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses), models: try json(models))
        // Codex is the Mac's default, but a phone never starts it: Claude stands in.
        #expect(catalog.harness("codex")?.isDefault == true)
        #expect(catalog.harness("codex")?.unavailableReason == "Not available from here: this agent has no mode that asks before each change")
        #expect(catalog.defaultChoice?.id == "claude")
        // The Mac's default first in the list, then by name.
        #expect(catalog.harnesses.first?.id == "codex")
    }

    @Test func aStartableDefaultIsUsed() throws {
        var reply = try json(harnesses)
        if case .object(var object) = reply {
            object["defaultHarness"] = .string("claude-cr")
            reply = .object(object)
        }
        #expect(AgentCatalog(harnesses: reply).defaultChoice?.id == "claude-cr")
    }

    @Test func launchersAndTerminalHarnesses() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses), models: try json(models))
        // A terminal harness runs in a terminal tab, not as a chat.
        #expect(catalog.harness("muse") == nil)
        // The cmux router is Claude's automatic fallback, not an agent to pick (acpmux `pickerHidden`).
        #expect(catalog.harness("cmux") == nil)
        // A launcher that can't run is Unavailable with the Mac's reason; a failed probe alone is not.
        #expect(catalog.harness("gemini")?.unavailableReason == "gemini is not installed")
        #expect(catalog.harness("pi")?.canStart == true)
        #expect(catalog.harness("claude")?.name == "Claude Code")
        #expect(catalog.harness("claude-cr")?.name == "Claude (CodeRouter)")
    }

    @Test func modelsAndTheirDefault() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses), models: try json(models))
        let claude = try #require(catalog.harness("claude"))
        #expect(claude.defaultModel == "opus")
        #expect(claude.models.map(\.id) == ["default", "opus", "sonnet", "haiku"])
        #expect(claude.models.last?.unavailableReason == "your plan does not include this model")
        // The default model is no model change; another model is.
        #expect(catalog.resolve(.macDefault)?.harness.id == "claude")
        #expect(catalog.resolve(.macDefault)?.model == nil)
        #expect(catalog.resolve(AgentChatStart(harness: "claude", model: "opus"))?.model == nil)
        #expect(catalog.resolve(AgentChatStart(harness: "claude", model: "sonnet"))?.model == "sonnet")
        // A harness a phone can't start resolves to nothing (the toast says why).
        #expect(catalog.resolve(AgentChatStart(harness: "codex")) == nil)
        #expect(catalog.resolve(AgentChatStart(harness: "gemini")) == nil)
    }

    /// acpmux refuses a profile that runs Codex under another family name.
    @Test func aRenamedCodexIsStillRefused() throws {
        let reply = try json(#"{"harnesses": {"mine": {"argv": ["npx", "-y", "@agentclientprotocol/codex-acp@1.10.0"], "family": "mine"}, "claude": {"argv": ["claude"], "family": "claude"}}}"#)
        #expect(AgentCatalog(harnesses: reply).harness("mine")?.unavailableReason == AgentCatalog.refusedReason)
        #expect(AgentCatalog(harnesses: reply).harness("claude")?.canStart == true)
    }

    @Test func nothingStartable() throws {
        let only = try json(#"{"defaultHarness": "codex", "harnesses": {"codex": {"argv": ["codex-acp"]}, "opencode": {"argv": ["opencode", "acp"], "family": "opencode"}}}"#)
        let catalog = AgentCatalog(harnesses: only)
        #expect(catalog.defaultChoice == nil)
        #expect(catalog.unavailableReason == AgentCatalog.refusedReason)
        #expect(AgentCatalog(harnesses: try json(#"{"harnesses": {}}"#)).unavailableReason == "No agents are set up in cmux on this Mac.")
    }
}

/// Parity round 2: a Mac that says what a phone may start (acpmux `remote`) decides it, so
/// Codex (the `codex app-server` bridge, started in its asking mode) is startable; and the
/// phone's New Agent Chat starts where the Mac's last pick does (acpmux `lastPicks`).
@Suite struct AgentCatalogRemoteTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    var harnesses: String {
        """
        {"defaultHarness": "claude",
         "harnesses": {
           "codex": {"argv": ["/opt/homebrew/bin/codex", "app-server"], "family": "codex",
                     "remote": {"startable": true, "modes": ["ask"]}},
           "codex-acp": {"argv": ["codex-acp"], "family": "codex",
                         "remote": {"startable": false, "reason": "this agent has no mode that asks before each change"}},
           "opencode": {"argv": ["opencode", "acp"], "family": "opencode",
                        "remote": {"startable": false, "reason": "this agent has no mode that asks before each change"}},
           "claude": {"argv": ["claude"], "family": "claude", "start": {"model": "claude-opus-5-5"},
                      "remote": {"startable": true, "modes": ["default", "plan"]}},
           "cmux": {"argv": ["claude"], "family": "claude", "remote": {"startable": true, "modes": ["default", "plan"]}}
         },
         "lastPicks": {"lastAgent": "codex",
                       "global": {"harness": "codex", "model": "gpt-5.5"},
                       "folders": [{"folder": "/Users/p/web", "harness": "cmux", "model": "z-ai/glm-5.3"},
                                   {"folder": "/Users/p/old", "harness": "opencode", "model": "x"}]}}
        """
    }

    @Test func codexOnTheBridgeIsStartableInItsAskingMode() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses))
        let codex = try #require(catalog.harness("codex"))
        #expect(codex.canStart)
        #expect(codex.askingModes == ["ask"])
        #expect(catalog.harness("codex-acp")?.unavailableReason == AgentCatalog.refusedReason)
        #expect(catalog.harness("opencode")?.unavailableReason == AgentCatalog.refusedReason)
        #expect(catalog.harness("claude")?.askingModes == ["default", "plan"])
    }

    /// An older Mac (no `remote`): Codex stays refused, since its acpmux would leave a
    /// phone-started Codex in a mode that does not ask.
    @Test func anOlderMacKeepsCodexRefused() throws {
        let reply = try json(#"{"harnesses": {"codex": {"argv": ["codex", "app-server"], "family": "codex"}}}"#)
        #expect(AgentCatalog(harnesses: reply).harness("codex")?.canStart == false)
    }

    @Test func newAgentChatStartsWhereTheMacsLastPickDoes() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses))
        // The folder's own pick wins.
        let inWeb = try #require(catalog.resolve(.macDefault, folder: "/Users/p/web"))
        #expect(inWeb.harness.id == "cmux")
        #expect(inWeb.model == "z-ai/glm-5.3")
        // Elsewhere: the pick anywhere.
        let elsewhere = try #require(catalog.resolve(.macDefault, folder: "/Users/p/other"))
        #expect(elsewhere.harness.id == "codex")
        #expect(elsewhere.model == "gpt-5.5")
        // A folder pick the phone can't start falls to the pick anywhere.
        #expect(catalog.resolve(.macDefault, folder: "/Users/p/old")?.harness.id == "codex")
        // A start that names a harness is not the Mac's default.
        #expect(catalog.resolve(AgentChatStart(harness: "claude"), folder: "/Users/p/web")?.harness.id == "claude")
        // The agent alone (no model pick): its own default model.
        var agentOnly = catalog
        agentOnly.lastPicks = AgentLastPicks(lastAgent: "codex")
        let picked = try #require(agentOnly.resolve(.macDefault))
        #expect(picked.harness.id == "codex")
        #expect(picked.model == nil)
        // No picks: the Mac's default agent.
        agentOnly.lastPicks = nil
        #expect(agentOnly.resolve(.macDefault)?.harness.id == "claude")
    }

    /// Full verify D4: Default on a named agent is the Mac's own pick for that agent, and a
    /// catalog default the Mac's account doesn't list is not offered by name.
    @Test func defaultOnANamedAgentIsTheMacsOwnPick() throws {
        let catalog = AgentCatalog(harnesses: try json(harnesses))
        #expect(catalog.resolve(AgentChatStart(harness: "codex"), folder: "/Users/p/other")?.model == "gpt-5.5")
        #expect(catalog.resolve(AgentChatStart(harness: "cmux"), folder: "/Users/p/web")?.model == "z-ai/glm-5.3")
        // No pick for that agent: the agent's own default (none sent).
        #expect(catalog.resolve(AgentChatStart(harness: "claude"), folder: "/Users/p/web")?.model == nil)
        // An explicit model still wins.
        #expect(catalog.resolve(AgentChatStart(harness: "codex", model: "gpt-6-astra"))?.model == "gpt-6-astra")
    }

    @Test func aDefaultTheAccountDoesNotListIsNotNamed() {
        let listed = AgentHarnessChoice(id: "codex", name: "Codex", family: "codex",
                                        models: [AgentModelChoice(id: "gpt-5.5", name: "GPT-5.5")], defaultModel: "gpt-5.5")
        #expect(listed.offeredDefaultModel == "gpt-5.5")
        let unlisted = AgentHarnessChoice(id: "codex", name: "Codex", family: "codex",
                                          models: [AgentModelChoice(id: "gpt-5.5", name: "GPT-5.5")], defaultModel: "gpt-6.1-sol")
        #expect(unlisted.offeredDefaultModel == nil)
        // No list (Claude Code): the default stands.
        #expect(AgentHarnessChoice(id: "claude", name: "Claude", family: "claude", defaultModel: "opus").offeredDefaultModel == "opus")
    }

    @Test func aPhonePicksOnlyModesThatAsk() {
        let modes = ["default", "acceptEdits", "plan", "bypassPermissions", "ask", "agent", "agent-full-access"]
            .map { ACPMode(id: $0, name: $0) }
        #expect(ACPMode.phoneChoices(modes, current: "default").map(\.id) == ["default", "plan", "ask"])
        // The current mode stays listed (checked) even when it does not ask.
        #expect(ACPMode.phoneChoices(modes, current: "agent").map(\.id) == ["default", "plan", "ask", "agent"])
    }

    /// A phone whose Full-access setting covers it (acpmux `initialize` `fullAccess`) also gets
    /// the harness's Full access mode, the one the Mac offers; never the other modes that do not
    /// ask (`acceptEdits`, the bridge's `agent`).
    @Test func aPhoneWithFullAccessAlsoPicksTheFullAccessMode() {
        let modes = ["default", "acceptEdits", "plan", "bypassPermissions", "ask", "agent", "agent-full-access"]
            .map { ACPMode(id: $0, name: $0) }
        #expect(ACPMode.phoneChoices(modes, current: "default", fullAccess: true).map(\.id)
            == ["default", "plan", "bypassPermissions", "ask", "agent-full-access"])
        #expect(ACPMode.phoneChoices(modes, current: "default", fullAccess: false).map(\.id) == ["default", "plan", "ask"])
        #expect(ACPMode.phoneChoices(modes, current: "agent", fullAccess: true).map(\.id)
            == ["default", "plan", "bypassPermissions", "ask", "agent", "agent-full-access"])
    }
}

/// New Workspace in a folder (Recent Directories): the new terminal changes to it as the
/// person would type; the phone never sends `cwd`. Agent chats never start in a home folder.
@Suite struct WorkspaceFolderTests {
    @Test func changeDirectoryLines() {
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~/Development/cmux") == "cd ~/'Development/cmux' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/tmp/it's here") == "cd '/tmp/it'\\''s here' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~") == nil)
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("relative") == nil)
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/x\nrm -rf ~") == nil)
    }

    /// Review 2026-10-15: the line is typed into a shell, whose line editor acts on control
    /// characters even inside quotes (DEL erases the quote, ^U the line), and fish reads `\'`
    /// inside single quotes. Such folders are never typed.
    @Test func foldersThatCouldEditTheLineAreNeverTyped() {
        for name in ["/tmp/x\u{7f}\u{7f} rm -rf ~ #", "/tmp/a\u{15}b", "/tmp/a\tb", "/tmp/a\u{1b}[Ab", "/tmp/a\\'b",
                     "/tmp/trailing\\", "/tmp/bang!", "/tmp/a\u{200b}b", "/tmp/a\u{2028}b"] {
            #expect(LiveWorkspaceCreationBackend.changeDirectoryLine(name) == nil, "\(name.debugDescription)")
        }
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/tmp/plain dir (2)") == "cd '/tmp/plain dir (2)' && clear\n")
    }

    /// Review 2026-10-15: `move-tab`'s index is an insertion point (the daemon uses index - 1
    /// past the tab's own place), and a drag never moves a tab into another pane.
    @Test func moveIndexes() {
        let at = { (pane: Int, index: Int) in DaemonTree.TabPlace(pane: pane, index: index) }
        #expect(LiveWorkspaceCreationBackend.moveIndex(from: at(1, 0), to: at(1, 2)) == 3)
        #expect(LiveWorkspaceCreationBackend.moveIndex(from: at(1, 0), to: at(1, 1)) == 2)
        #expect(LiveWorkspaceCreationBackend.moveIndex(from: at(1, 2), to: at(1, 0)) == 0)
        #expect(LiveWorkspaceCreationBackend.moveIndex(from: at(1, 0), to: at(2, 0)) == nil)
    }

    @Test func homeAndAboveAreNoProject() {
        for path in ["/", "/Users", "/Users/aziz", "/Users/aziz/", "/var/root"] {
            #expect(LiveWorkspaceCreationBackend.isHomeOrAbove(path), "\(path)")
        }
        for path in ["/Users/aziz/Projects/mario", "/tmp/x", "/Volumes/work", "/Users/Shared"] {
            #expect(!LiveWorkspaceCreationBackend.isHomeOrAbove(path), "\(path)")
        }
    }
}
