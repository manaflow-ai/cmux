@testable import CmuxNextApp
import CmuxNextWindowRules
import Testing

/// The agent chat handlers' rules answer through the app FFI (cmux-window-rules `chat::agent`, whose own tests hold the
/// cases): these check the round trip, the facts the app sends and the answers it reads back.
@MainActor @Suite struct WindowRulesChatAgentTests {
    @Test func theTablesListThePageCommandsAndTheTeamLines() throws {
        let tables = try #require(WindowRules.chatAgentTables, "the FFI did not answer")
        #expect(tables.pageCommands.filter(\.refusesRemote).map(\.action) == ["agentPane.editInstructions", "agentPane.addProjectFiles"])
        #expect(tables.teams.map(\.harness) == ["claude", "codex"])
        #expect(AgentTeamsLaunch(actionID: "palette.launchCodexTeams") == .codex)
        #expect(AgentTeamsLaunch.codex.shellLine == "codex -c features.multi_agent=true\n")
    }

    @Test func zoomClampsToTheSettingsRange() throws {
        let zoom = try #require(WindowRules().chatZoom(current: 1.95, delta: 0.1, range: 0.5...2.0), "the FFI did not answer")
        #expect(zoom.zoom == 2.0 && zoom.percent == 200)
    }

    @Test func openFileChecksItsPlaceAndPath() {
        let rules = WindowRules()
        #expect(rules.chatFilePlace(path: "", place: nil, namesPane: false, hasFocusedPane: false) == .picker)
        #expect(rules.chatFilePlace(path: "/a", place: "editor", namesPane: false, hasFocusedPane: false) == .open(target: "editor", paneless: true))
        #expect(rules.chatFileCheck(path: "/a", target: "editor", remote: true) == .some(.remotePreview))
        #expect(rules.chatFileCheck(path: "/a", target: "tab", remote: false) == .some(nil))
    }

    @Test func aPeerChatKeepsALocalPaneAndTakesThePeerAsHost() throws {
        let facts = WindowRules.ChatHostFacts(route: .peer("blue"), ready: true, cancelled: false, targeted: false,
                                              targetLocal: false, activeLocal: true)
        let plan = try #require(WindowRules().chatHostPlan(facts), "the FFI did not answer")
        #expect(plan.host == "blue")
        #expect(plan.open == .local)
    }

    @Test func aTargetedChatOnAPaneNoWindowShowsOpensOnTheStoreSelected() {
        #expect(WindowRules().chatTargetedRoute(applies: true, pane: true, found: true, shown: false, shownDocksChat: false,
                                                allowsViewChange: false) == .store(selects: true))
        #expect(WindowRules().chatPaneRoute(targeted: false, hasPane: true, topPage: true, hasWorkspace: true) == .overTopPage)
    }

    @Test func theInspectorOpensInHomesRightColumn() {
        let columns = [WindowRules.InspectorColumn(panes: [1], dock: true), WindowRules.InspectorColumn(panes: [2], dock: false)]
        #expect(WindowRules().inspectorPlacement(focused: 1, inHome: true, columns: columns) == .tab(2))
        #expect(WindowRules().inspectorAnchor(targeted: false, paneInHome: nil, scopeWorkspace: nil,
                                              workspaces: [.init(home: true, hasPane: true), .init(home: false, hasPane: true)]) == .workspace(1))
    }

    @Test func aMemoryRouteRoundTrips() throws {
        let route = try #require(ChiefMemoryRoute(place: .server(machineID: "mini")).persisted)
        #expect(route == "server:mini")
        #expect(ChiefMemoryRoute(route) == ChiefMemoryRoute(place: .server(machineID: "mini")))
        #expect(ChiefMemoryRoute("cloud:x") == nil)
    }

    @Test func twoHarnessesSharingAShortNameShowNeitherUnderIt() throws {
        let catalog = try #require(WindowRules().modelCatalog([
            .init(harness: "claude", models: [.init(id: "a", name: nil)]),
            .init(harness: "peer/claude", models: [.init(id: "b", name: "B")]),
        ]))
        #expect(catalog.map(\.harness) == ["peer/claude"])
        #expect(catalog.first?.models.map(\.title) == ["B"])
    }

    @Test func anAgentWorkspaceInAGroupTakesNoDefaultSlot() throws {
        let placement = try #require(WindowRules().sessionPlacement(group: true, top: false))
        #expect(placement.joinsGroup && !placement.belowCaller && placement.defaultSlot == nil)
    }
}
