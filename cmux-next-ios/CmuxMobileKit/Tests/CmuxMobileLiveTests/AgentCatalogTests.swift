import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
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

/// New Task's first message: its photos inline and its files as links to their uploaded copies,
/// built by the chat's own prompt builder.
@Suite struct TaskPromptBlockTests {
    @Test func photosGoInlineAndFilesAsTheirUploadedCopies() {
        let png = TaskImage(id: "a", data: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 12)))
        let file = TaskFile(id: "f", name: "trace.bin", data: Data(repeating: 0, count: 300 << 10))
        let attachments = LiveWorkspaceCreationBackend.taskAttachments(AgentTask(prompt: "Match this", images: [png], files: [file]))
        #expect(attachments.map(\.kind) == [.image, .file])
        let blocks = AcpmuxSessionSource.promptBlocks(text: "Match this", attachments: attachments,
                                                      uploaded: ["f": "/Users/me/p/.cmux/attachments/trace.bin"])
        #expect(blocks.map { $0["type"]?.stringValue } == ["text", "image", "resource_link"])
        #expect(blocks[2]["uri"]?.stringValue == "file:///Users/me/p/.cmux/attachments/trace.bin")
    }
}

/// What a failed first send means (fourth verifier: a write failure or a cancel read as the
/// agent's refusal): only acpmux's RPC error is the agent's answer.
@MainActor @Suite struct TaskDeliveryFailureTests {
    @Test func onlyTheAgentsAnswerIsARefusal() {
        if case .notSent = LiveWorkspaceCreationBackend.deliveryFailure(LinkError(code: "offline", message: "x")) {} else { Issue.record("offline") }
        if case .uncertain = LiveWorkspaceCreationBackend.deliveryFailure(LinkError(code: "timeout", message: "x")) {} else { Issue.record("timeout") }
        if case .uncertain = LiveWorkspaceCreationBackend.deliveryFailure(CancellationError()) {} else { Issue.record("cancel") }
    }
}

/// New Task's Effort, Mode and option pickers list only what the Mac sends: each model's efforts
/// (`_acpmux/models`), the modes a phone may start (`remote.modes`) by the names its chats use,
/// and the agent's own options as its chats report them (`reported`).
@Suite struct AgentSettingsFromTheMacTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    var harnesses: String {
        """
        {"defaultHarness": "claude",
         "harnesses": {
           "claude": {"family": "claude", "start": {"model": "opus", "effort": "high"},
             "remote": {"startable": true, "modes": ["default", "plan"]},
             "reported": {
               "modes": [{"id": "auto", "name": "Auto"}, {"id": "default", "name": "Manual", "description": "Always ask before making changes"},
                         {"id": "plan", "name": "Plan", "description": "Create a plan before making changes"}],
               "configOptions": [
                 {"id": "effort", "name": "Effort", "category": "thought_level", "type": "select",
                  "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}, {"value": "xhigh", "name": "Extra High"}]},
                 {"id": "model", "name": "Model", "category": "model", "type": "select", "options": [{"value": "opus", "name": "Opus"}, {"value": "sonnet", "name": "Sonnet"}]},
                 {"id": "fast-mode", "name": "Fast mode", "type": "select", "remoteSettable": false, "options": [{"value": "off", "name": "Off"}, {"value": "on", "name": "On"}]},
                 {"id": "style", "name": "Style", "type": "select", "remoteSettable": true,
                  "options": [{"group": "g", "name": "Concise", "options": [{"value": "terse", "name": "Terse"}, {"value": "brief", "name": "Brief"}]}]},
                 {"id": "session-recap", "name": "Session recap", "type": "select", "options": [{"value": "off"}, {"value": "on"}]},
                 {"id": "one", "name": "One choice", "type": "select", "options": [{"value": "only"}]},
                 {"id": "flag", "name": "A toggle", "type": "boolean"}]}},
           "fresh": {"family": "fresh", "remote": {"startable": true, "modes": ["ask"]}}
         }}
        """
    }

    var models: String {
        """
        {"harnesses": [{"harness": "claude", "models": [
          {"id": "opus", "name": "Opus", "efforts": ["low", "high", "xhigh"], "defaultEffort": "high"},
          {"id": "haiku", "name": "Haiku"}]}]}
        """
    }

    @Test func effortsComeFromEachModelAndAreNamedAsTheAgentNamesThem() throws {
        let claude = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("claude"))
        #expect(claude.efforts(model: "opus").map(\.id) == ["low", "high", "xhigh"])
        #expect(claude.efforts(model: "opus").map(\.name) == ["Low", "High", "Extra High"])
        #expect(claude.defaultEffort(model: "opus") == "high")
        // A model that lists none: the agent's effort option.
        #expect(claude.efforts(model: "haiku").map(\.id) == ["low", "high", "xhigh"])
        #expect(claude.startEffort == "high")
    }

    @Test func modesAreOnlyTheOnesAPhoneMayStartNamedByTheAgent() throws {
        let catalog = try AgentCatalog(harnesses: json(harnesses), models: json(models))
        let claude = try #require(catalog.harness("claude"))
        #expect(claude.modes.map(\.id) == ["default", "plan"])
        #expect(claude.modes.map(\.name) == ["Manual", "Plan"])
        #expect(claude.modes.first?.detail == "Always ask before making changes")
        // No chat reported names yet: the id, readable.
        #expect(try #require(catalog.harness("fresh")).modes.map(\.name) == ["Ask"])
    }

    @Test func otherOptionsAreTheAgentsOwnWithChoices() throws {
        let claude = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("claude"))
        // Not the model or effort (their own pickers), a per-chat switch, one choice, a non-select,
        // nor one a phone may not set (Fast mode: the Mac's remote rule refuses it).
        #expect(claude.configOptions.map(\.id) == ["style"])
        #expect(claude.configOptions[0].choices.map(\.id) == ["terse", "brief"])
        #expect(claude.effortOption?.id == "effort")
    }

    @Test func aMacThatSendsNoneOffersNone() throws {
        let fresh = try #require(AgentCatalog(harnesses: json(harnesses)).harness("fresh"))
        #expect(fresh.efforts(model: nil).isEmpty && fresh.configOptions.isEmpty && fresh.effortOption == nil)
    }
}

/// The mode and effort a new chat starts with, read from acpmux's harness row: the first
/// `remote.modes` named by `reported.modes`, and `start.effort` with or without `start.model`
/// (Leo, 2026-11-22: "opus 5.5 should have medium selected at baseline in the new chat area").
@MainActor
@Suite struct StartStateFromTheMacTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    let harnesses = """
    {"defaultHarness": "claude",
     "harnesses": {
       "claude": {"family": "claude", "start": {"model": "opus", "effort": "medium", "modelSource": "harness", "effortSource": "saved"},
         "remote": {"startable": true, "modes": ["auto", "default"]},
         "reported": {"modes": [{"id": "default", "name": "Manual"}, {"id": "auto", "name": "Auto", "description": "Asks only when it must"}]}},
       "profile": {"family": "claude", "start": {"effort": "medium", "effortSource": "model"},
         "remote": {"startable": true, "modes": ["accept-edits"]}}
     }}
    """
    let models = """
    {"harnesses": [{"harness": "claude", "models": [
      {"id": "claude-opus-5-5", "name": "Claude Opus 5.5", "shortName": "Opus 5.5", "aliases": ["opus"],
       "efforts": ["low", "medium", "high"], "defaultEffort": "high"}]}]}
    """

    actor Sent {
        var calls: [(String, JSONValue)] = []
        func send(_ method: String, _ params: JSONValue) { calls.append((method, params)) }
    }

    @Test func theStartModeIsTheFirstRemoteModeByItsReportedName() throws {
        let claude = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("claude"))
        #expect(claude.askingModes.first == "auto" && claude.modes.first?.name == "Auto")
        // Not reported: its id, readable.
        let profile = try #require(AgentCatalog(harnesses: json(harnesses)).harness("profile"))
        #expect(profile.modes.map(\.name) == ["Accept edits"])
    }

    @Test func theStartEffortIsTheStartModelsLevelOverItsOwnDefault() throws {
        let claude = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("claude"))
        #expect(claude.startsOn("claude-opus-5-5") && claude.startsOn(nil))
        #expect(claude.defaultEffort(model: "claude-opus-5-5") == "medium")
    }

    @Test func theStartEffortIsShownAndSentWithoutAStartModel() async throws {
        let profile = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("profile"))
        #expect(profile.defaultModel == nil && profile.startEffort == "medium")
        #expect(profile.efforts(model: nil).map(\.name) == ["Medium"] && profile.defaultEffort(model: nil) == "medium")
        // What the pill shows is what the new chat is set to; its only mode needs no request.
        let sent = Sent()
        let start = AgentChatStart(harness: "profile", effort: profile.defaultEffort(model: nil), mode: profile.askingModes.first)
        await LiveWorkspaceCreationBackend.applyStartSettings(start, to: "s1", choice: profile) { await sent.send($0, $1) }
        let calls = await sent.calls
        #expect(calls.map(\.0) == ["session/set_config_option"])
        #expect(calls.first?.1["configId"]?.stringValue == "effort" && calls.first?.1["value"]?.stringValue == "medium")
    }
}

/// A new chat gets the phone's effort, mode and options before its first prompt, each only when
/// the Mac offers it for that agent and model; one the Mac refuses never stops the others.
@MainActor
@Suite struct StartSettingsTests {
    actor Sent {
        var calls: [(String, JSONValue)] = []
        var refuse: String?
        init(refuse: String? = nil) { self.refuse = refuse }
        func send(_ method: String, _ params: JSONValue) throws {
            calls.append((method, params))
            if params["configId"]?.stringValue == refuse { throw CancellationError() }
        }
    }

    let claude = AgentHarnessChoice(
        id: "claude", name: "Claude Code", family: "claude",
        models: [AgentModelChoice(id: "opus", name: "Opus", efforts: ["low", "high", "max"]), AgentModelChoice(id: "haiku", name: "Haiku")],
        defaultModel: "opus", askingModes: ["default", "plan"],
        effortOption: AgentConfigChoice(id: "effort", name: "Effort", category: "thought_level",
                                        choices: [AgentSettingChoice(id: "low", name: "Low")]),
        configOptions: [AgentConfigChoice(id: "fast-mode", name: "Fast mode",
                                          choices: [AgentSettingChoice(id: "off", name: "Off"), AgentSettingChoice(id: "on", name: "On")])])

    @Test func theOfferedPicksAreSetInOrder() async {
        let sent = Sent()
        let start = AgentChatStart(harness: "claude", model: "opus", effort: "max", mode: "plan", options: ["fast-mode": "on"])
        await LiveWorkspaceCreationBackend.applyStartSettings(start, to: "s1", choice: claude) { try await sent.send($0, $1) }
        let calls = await sent.calls
        #expect(calls.map(\.0) == ["session/set_config_option", "session/set_mode", "session/set_config_option"])
        #expect(calls[0].1["configId"]?.stringValue == "effort" && calls[0].1["value"]?.stringValue == "max")
        #expect(calls[1].1["modeId"]?.stringValue == "plan" && calls[1].1["sessionId"]?.stringValue == "s1")
        #expect(calls[2].1["configId"]?.stringValue == "fast-mode" && calls[2].1["value"]?.stringValue == "on")
    }

    @Test func whatTheMacDoesNotOfferIsNeverSent() async {
        let sent = Sent()
        // Max is not Haiku's (it lists none: the effort option's Low only); bypassPermissions
        // is not a mode a phone may start; the start mode needs no request; unknown options go.
        let start = AgentChatStart(harness: "claude", model: "haiku", effort: "max", mode: "bypassPermissions",
                                   options: ["fast-mode": "turbo", "sandbox": "off"])
        await LiveWorkspaceCreationBackend.applyStartSettings(start, to: "s1", choice: claude) { try await sent.send($0, $1) }
        #expect(await sent.calls.isEmpty)
        let startMode = AgentChatStart(harness: "claude", model: "opus", mode: "default")
        await LiveWorkspaceCreationBackend.applyStartSettings(startMode, to: "s1", choice: claude) { try await sent.send($0, $1) }
        #expect(await sent.calls.isEmpty)
    }

    @Test func aRefusalLeavesTheRestToBeSet() async {
        let sent = Sent(refuse: "effort")
        let start = AgentChatStart(harness: "claude", model: "opus", effort: "high", options: ["fast-mode": "on"])
        await LiveWorkspaceCreationBackend.applyStartSettings(start, to: "s1", choice: claude) { try await sent.send($0, $1) }
        #expect(await sent.calls.map { $0.1["configId"]?.stringValue } == ["effort", "fast-mode"])
    }
}

/// New Task's model picker lists each release by its version ("Opus 5.5", "Opus 5"), as the
/// Mac's catalog names them; current ones apart from older ones; an alias names its release.
@Suite struct ModelVersionsTests {
    func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    let harnesses = """
    {"defaultHarness": "claude", "harnesses": {"claude": {"family": "claude", "start": {"model": "opus"},
      "remote": {"startable": true, "modes": ["default", "plan"]}}}}
    """
    let models = """
    {"harnesses": [{"harness": "claude", "topModels": ["claude-opus-5-5", "claude-sonnet-5-5"], "models": [
      {"id": "default", "name": "Default (Claude Code's choice)"},
      {"id": "claude-opus-5-5", "name": "Claude Opus 5.5", "shortName": "Opus 5.5", "aliases": ["opus"], "curated": true},
      {"id": "claude-sonnet-5-5", "name": "Claude Sonnet 5.5", "shortName": "Sonnet 5.5", "aliases": ["sonnet"], "curated": true},
      {"id": "claude-opus-5", "name": "Claude Opus 5", "shortName": "Opus 5", "curated": true}]}]}
    """

    @Test func releasesAreNamedByVersionAndSplitCurrentFromOlder() throws {
        let claude = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("claude"))
        #expect(claude.models.first { $0.id == "claude-opus-5-5" }?.displayName == "Opus 5.5")
        #expect(claude.models.first { $0.id == "claude-opus-5" }?.isCurrent == false)
        #expect(claude.models.first { $0.id == "claude-sonnet-5-5" }?.isCurrent == true)
    }

    @Test func anAliasNamesItsRelease() throws {
        let claude = try #require(AgentCatalog(harnesses: json(harnesses), models: json(models)).harness("claude"))
        #expect(claude.model("opus")?.id == "claude-opus-5-5")
        #expect(claude.offeredDefaultModel == "claude-opus-5-5")
    }
}
