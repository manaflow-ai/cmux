#if DEBUG
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp

/// `debug.agent_pane open_subagent` (cmux#28213): the captures that record where subagent panes
/// land clicked the tray, whose `chat.subagentPane` a showcase chat refuses (its page never
/// persists the mock daemon's session, so the model has none) and shows the subagent in the chat
/// instead. The debug open runs the chat's own header hook into AgentTabStore's openSubagent, so
/// the subagent tracker and openBeside's placement are the real ones, on the page's session.
@MainActor
struct DebugAgentPaneSubagentTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// What the store's placement was asked: the main-pane open (chat, focus) and the panes located.
    @MainActor private final class Placement {
        var mainPane: [(chat: String, focus: Bool)] = []
        var located: [String] = []
        var pageReads = 0
    }

    /// A chat tab `chat` wired as the app wires one (the header hooks hold the store weakly, so the
    /// test keeps it), whose main-pane open answers `placed` and makes tab `created` when it places one.
    private func chat(_ chat: String, sessionId: String? = nil, placed: Bool?, created: String = "subagent-tab")
        -> (model: AgentPaneModel, placement: Placement, tabs: AgentTabStore) {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        let placement = Placement()
        tabs.openInMainPane = { target, focus, _, made, _ in
            placement.mainPane.append((chat: target, focus: focus))
            if placed == true { made?(created) }
            return placed
        }
        tabs.locate = { key in placement.located.append(key); return nil }
        let model = AgentPaneModel(host: NoHost(), sessionId: sessionId)
        tabs.wireHeader(model, key: chat)
        return (model, placement, tabs)
    }

    @Test func indexesNameTheFixtureSubagentsInOrder() {
        #expect(DebugAgentPaneSubagent.fixtureAgent(1) == "fixture-reviewer")
        #expect(DebugAgentPaneSubagent.fixtureAgent(2) == "fixture-auditor")
        #expect(DebugAgentPaneSubagent.fixtureAgent(3) == "fixture-helper-1")
        #expect(DebugAgentPaneSubagent.fixtureAgent(8) == "fixture-helper-6")
        #expect(DebugAgentPaneSubagent.fixtureAgent(0) == nil)
        #expect(DebugAgentPaneSubagent.fixtureAgent(9) == nil)
    }

    @Test func aShowcaseChatOpensItsSubagentThroughThePlacementOnThePagesSession() async {
        let session = "mock-\(UUID().uuidString)"
        let (model, placement, tabs) = chat("chat-tab", placed: true)
        let result = await DebugAgentPaneSubagent.open(["index": .number(3)], pane: "pane-1", model: model) {
            placement.pageReads += 1
            return session
        }
        #expect(result == .object(["pane": .string("pane-1"), "opened": .bool(true), "agent": .string("fixture-helper-1")]))
        #expect(placement.pageReads == 1)
        // The placement opened it beside the chat, without focus (the chat keeps it).
        #expect(placement.mainPane.map(\.chat) == ["chat-tab"])
        #expect(placement.mainPane.map(\.focus) == [false])
        // The page's session's tracker holds the new tab: a repeat open shows it instead of opening another.
        #expect(AgentSubagentPanes.session("\(session):chat-tab").tab(for: "fixture-helper-1", isOpen: { _ in true }) == "subagent-tab")
        #expect(AgentSubagentPanes.session(session).tab(for: "fixture-helper-1", isOpen: { _ in true }) == nil,
                "a session tracker must not reuse a subagent opened beside another chat")
        withExtendedLifetime(tabs) {}
    }

    @Test func theModelsSessionWinsAndFocusIsPassed() async {
        let session = "chat-\(UUID().uuidString)"
        let (model, placement, tabs) = chat("chat-tab", sessionId: session, placed: true, created: "reviewer-tab")
        let result = await DebugAgentPaneSubagent.open(["index": .number(1), "focus": .bool(true)], pane: "pane-1", model: model) {
            placement.pageReads += 1
            return "other"
        }
        #expect(result == .object(["pane": .string("pane-1"), "opened": .bool(true), "agent": .string("fixture-reviewer")]))
        #expect(placement.pageReads == 0)
        #expect(placement.mainPane.map(\.focus) == [true])
        #expect(AgentSubagentPanes.session("\(session):chat-tab").tab(for: "fixture-reviewer", isOpen: { _ in true }) == "reviewer-tab")
        withExtendedLifetime(tabs) {}
    }

    @Test func aChatOutsideTheMainPaneIsLocatedAndARefusalAnswersSo() async {
        let session = "mock-\(UUID().uuidString)"
        let (model, placement, tabs) = chat("chat-tab", placed: nil)
        let result = await DebugAgentPaneSubagent.open(["index": .number(2)], pane: "pane-1", model: model) { session }
        // Not the main pane: openBeside locates the chat's pane, and none holds it here.
        #expect(placement.located == ["chat-tab"])
        #expect(result["opened"] == .bool(false))
        #expect(result["agent"] == .string("fixture-auditor"))
        #expect(result["error"]?.stringValue != nil)
        withExtendedLifetime(tabs) {}
    }

    @Test func aRefusedIndexOrNoSessionOpensNothing() async {
        let (model, placement, tabs) = chat("chat-tab", placed: true)
        for params: [String: CmuxNextSettings.JSONValue] in [[:], ["index": .number(0)], ["index": .number(9)], ["index": .number(1.5)]] {
            let result = await DebugAgentPaneSubagent.open(params, pane: "pane-1", model: model) { "mock" }
            #expect(result["error"]?.stringValue?.contains("index") == true)
        }
        let noSession = await DebugAgentPaneSubagent.open(["index": .number(1)], pane: "pane-1", model: model) { nil }
        #expect(noSession["error"]?.stringValue?.contains("send_prompt") == true)
        #expect(placement.mainPane.isEmpty && placement.located.isEmpty)
        withExtendedLifetime(tabs) {}
    }
}
#endif
