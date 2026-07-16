import CmuxAgentChat
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite
struct PaneRackNavigationTests {
    @Test func stagedPaneInitializesFromMacFocusAndFallsBackWhenPaneDisappears() throws {
        let workspace = makeWorkspace()
        let store = makeStore(workspaces: [workspace])
        enablePaneCapabilities(on: store)

        var snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        #expect(snapshot.stagedPaneID == "pane-b")
        #expect(store.selectedTerminalID?.rawValue == "terminal-3")

        store.stagePane("pane-a", in: workspace.id)
        snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        #expect(snapshot.stagedPaneID == "pane-a")
        #expect(store.selectedTerminalID?.rawValue == "terminal-2")

        var refreshed = workspace
        refreshed.terminals.removeAll { $0.paneID == "pane-a" }
        refreshed.panes.removeAll { $0.id == "pane-a" }
        install(refreshed, in: store)
        snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        #expect(snapshot.stagedPaneID == "pane-b")
        #expect(store.selectedTerminalID?.rawValue == "terminal-3")
    }

    @Test func perPaneSelectionPersistsLocallyThenInvalidatesWhenTabLeaves() throws {
        let workspace = makeWorkspace()
        let store = makeStore(workspaces: [workspace])
        enablePaneCapabilities(on: store)
        store.stagePane("pane-a", in: workspace.id)
        #expect(store.selectedTerminalID?.rawValue == "terminal-2")

        store.selectTab("terminal-1", inPane: "pane-a", workspaceID: workspace.id)
        #expect(store.selectedTerminalID?.rawValue == "terminal-1")

        var sameTabs = workspace
        sameTabs.panes[0].selectedTabID = "terminal-2"
        install(sameTabs, in: store)
        #expect(store.selectedTerminalID?.rawValue == "terminal-1")

        var terminalMoved = sameTabs
        terminalMoved.panes[0].tabIDs = ["terminal-2"]
        terminalMoved.terminals.removeAll { $0.id.rawValue == "terminal-1" }
        install(terminalMoved, in: store)
        #expect(store.selectedTerminalID?.rawValue == "terminal-2")
        let snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        #expect(snapshot.panes.first(where: { $0.id == "pane-a" })?.selectedTabID?.rawValue == "terminal-2")
    }

    @Test func oldMacSynthesizesImplicitPaneAndKeepsPhoneSelection() throws {
        let workspace = makeWorkspace(panes: [])
        let store = makeStore(workspaces: [workspace])
        store.supportedHostCapabilities = []
        store.syncSelectedTerminalForWorkspace()

        var snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        let implicitPane = try #require(snapshot.panes.first)
        #expect(snapshot.panes.count == 1)
        #expect(implicitPane.tabs.map(\.id.rawValue) == ["terminal-1", "terminal-2", "terminal-3"])
        #expect(implicitPane.selectedTabID?.rawValue == "terminal-3")
        #expect(!snapshot.canCloseTabs)

        store.selectTab("terminal-1", inPane: implicitPane.id, workspaceID: workspace.id)
        install(workspace, in: store)
        snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        #expect(snapshot.panes.first?.selectedTabID?.rawValue == "terminal-1")
        #expect(store.selectedTerminalID?.rawValue == "terminal-1")
    }

    @Test func agentStateJoinsCachedSessionsIntoTabSnapshots() throws {
        let workspace = makeWorkspace()
        let store = makeStore(workspaces: [workspace])
        enablePaneCapabilities(on: store)
        store.rememberChatSessions([
            ChatSessionDescriptor(
                id: "session-1",
                agentKind: .claude,
                workspaceID: workspace.id.rawValue,
                terminalID: "terminal-3",
                state: .needsInput(since: Date(timeIntervalSince1970: 1))
            ),
        ], workspaceID: workspace.id.rawValue)

        #expect(store.agentState(forTerminalID: "terminal-3") == .needsInput)
        let snapshot = try #require(store.paneRackSnapshot(for: workspace.id))
        let tab = snapshot.panes.flatMap(\.tabs).first { $0.id.rawValue == "terminal-3" }
        #expect(tab?.agentState == .needsInput)
        #expect(store.agentState(forTerminalID: "terminal-1") == .idle)
    }

    private func makeWorkspace(panes: [MobilePanePreview]? = nil) -> MobileWorkspacePreview {
        let terminals = [
            MobileTerminalPreview(id: "terminal-1", name: "one", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-2", name: "two", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-3", name: "three", isFocused: true, paneID: "pane-b"),
        ]
        return MobileWorkspacePreview(
            id: "workspace-1",
            name: "Agents",
            terminals: terminals,
            panes: panes ?? [
                MobilePanePreview(
                    id: "pane-a",
                    tabIDs: ["terminal-1", "terminal-2"],
                    selectedTabID: "terminal-2",
                    rect: MobilePaneNormalizedRect(x: 0, y: 0, w: 0.6, h: 1)
                ),
                MobilePanePreview(
                    id: "pane-b",
                    tabIDs: ["terminal-3"],
                    selectedTabID: "terminal-3",
                    isFocused: true,
                    rect: MobilePaneNormalizedRect(x: 0.6, y: 0, w: 0.4, h: 1)
                ),
            ]
        )
    }

    private func makeStore(workspaces: [MobileWorkspacePreview]) -> MobileShellComposite {
        let defaults = UserDefaults(suiteName: "PaneRackNavigationTests-\(UUID().uuidString)")!
        return MobileShellComposite(
            workspaces: workspaces,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults,
            groupCollapseStore: MobileWorkspaceGroupCollapseStore(defaults: defaults)
        )
    }

    private func enablePaneCapabilities(on store: MobileShellComposite) {
        store.supportedHostCapabilities = ["workspace.panes.v1", "terminal.close.v1"]
        store.syncSelectedTerminalForWorkspace()
    }

    private func install(_ workspace: MobileWorkspacePreview, in store: MobileShellComposite) {
        var state = store.workspacesByMac[MobileShellComposite.foregroundAnonymousKey]
            ?? MacWorkspaceState(macDeviceID: MobileShellComposite.foregroundAnonymousKey)
        state.workspaces = [workspace]
        store.workspacesByMac[MobileShellComposite.foregroundAnonymousKey] = state
    }
}
