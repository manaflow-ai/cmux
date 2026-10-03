import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneActionTests {
    @Test func newAgentChatIsBoundAndRunsWithItsTarget() {
        let registry = ActionRegistry.standard()
        var opened: [ActionTargetRef?] = []
        #expect(registry.bindAgentPane { opened.append($0.target) })
        #expect(registry.isBound(.newAgentChat))
        let pane = ActionTargetRef(kind: .pane, id: "pane-1")
        #expect(registry.perform(.newAgentChat, invocation: ActionInvocation(target: pane)))
        #expect(opened == [pane])
    }

    /// Every entrypoint comes from the descriptor: palette, File menu, the
    /// new-tab menu, and the CLI verb.
    @Test func theDescriptorReachesEveryEntrypoint() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == .newAgentChat })
        #expect(descriptor.cliName == "agent new-chat")
        #expect(descriptor.mainMenu == .file)
        #expect(descriptor.targets == [.pane])
        #expect(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .newTab)).contains(.newAgentChat))
    }

    /// The changed files' open is the catalog's `file.open`, so the page, the
    /// palette and `cmux file open` share one action.
    @Test func fileOpenIsACatalogAction() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == .fileOpen })
        #expect(descriptor.cliName == "file open")
        #expect(descriptor.arguments.map(\.name) == ["path", "where"])
    }

    /// The page hears a refusal as a failure: a handler that refuses (no pane,
    /// or a file that changed since the page's check) is not a success.
    @Test func theAgentPaneHearsWhenFileOpenRefuses() {
        let registry = ActionRegistry.standard()
        var asked: [ActionInvocation] = []
        // Bound outside #expect: the macro passes its call's arguments through a Sendable closure.
        let bound = registry.bind(.fileOpen, invoke: { invocation in
            asked.append(invocation)
            if invocation["where"]?.stringValue == "editor" { registry.refuse("no editor") }
        })
        #expect(bound)
        #expect(registry.openAgentFile(path: "/repo/Retry.swift", target: .tab, pane: "pane-1"))
        #expect(asked.last?.target == ActionTargetRef(kind: .pane, id: "pane-1"))
        #expect(asked.last?["path"]?.stringValue == "/repo/Retry.swift")
        #expect(!registry.openAgentFile(path: "/repo/Retry.swift", target: .editor, pane: "pane-1"))
        #expect(asked.count == 2)
    }

    @Test func continueInUsesTheFrontendCommand() throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-continue-in-test.html")
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.showContinueIn()
        #expect(scripts == ["window.cmuxAcpmuxBridge?.command?.(\"continueIn\");"])
    }

    /// A `#turn-<turnId>` link asks a loaded page to scroll to that turn;
    /// the id reaches the page as a JSON string, never as script text.
    @Test func revealTurnAsksThePageToScrollToTheTurn() async throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-reveal-turn-test.html")
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        _ = await view.model.respond(to: .ready)
        view.revealTurn("turn-1")
        view.revealTurn("a\");alert(1);//")
        #expect(scripts == [
            "window.cmuxAcpmuxBridge?.revealTurn?.(\"turn-1\");",
            "window.cmuxAcpmuxBridge?.revealTurn?.(\"a\\\");alert(1);//\");",
        ])
        #expect(view.model.pendingRevealTurn == nil)
    }

    /// A page that has not loaded yet (a tab the link just opened) has no
    /// bridge: the turn waits on the model and rides the handshake, once.
    @Test func aTurnForAPageNotLoadedYetRidesTheHandshake() async throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-pending-turn-test.html")
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost(), sessionId: "s1"), source: .bundled(page)))
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.revealTurn("t-7")
        #expect(scripts.isEmpty)
        #expect(view.model.pendingRevealTurn == "t-7")
        let first = try #require(await view.model.respond(to: .ready)["value"] as? [String: Any])
        #expect(first["revealTurn"] as? String == "t-7")
        let again = try #require(await view.model.respond(to: .reconnect)["value"] as? [String: Any])
        #expect(again["revealTurn"] == nil, "a reconnect does not scroll again")
    }
}
