import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite
struct PaneRackCloseTests {
    @Test func optimisticCloseRollsBackAndSurfacesLastTerminalFailure() async throws {
        let sender = ControllablePaneRackRequestSender()
        let workspace = MobileWorkspacePreview(
            id: "workspace-1",
            name: "Agents",
            terminals: [
                MobileTerminalPreview(id: "terminal-1", name: "one", paneID: "pane-a"),
                MobileTerminalPreview(id: "terminal-2", name: "two", paneID: "pane-a"),
            ],
            panes: [
                MobilePanePreview(
                    id: "pane-a",
                    tabIDs: ["terminal-1", "terminal-2"],
                    selectedTabID: "terminal-1",
                    isFocused: true,
                    rect: MobilePaneNormalizedRect(x: 0, y: 0, w: 1, h: 1)
                ),
            ]
        )
        let defaults = UserDefaults(suiteName: "PaneRackCloseTests-\(UUID().uuidString)")!
        let store = MobileShellComposite(
            workspaces: [workspace],
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults,
            groupCollapseStore: MobileWorkspaceGroupCollapseStore(defaults: defaults)
        )
        store.paneRackRequestSender = sender
        store.supportedHostCapabilities = ["workspace.panes.v1", "terminal.close.v1"]
        store.syncSelectedTerminalForWorkspace()

        let closeTask = Task { @MainActor in
            await store.closeTab("terminal-2", workspaceID: workspace.id)
        }
        let request = await sender.nextRequest()
        #expect(request.method == "mobile.terminal.close")
        #expect(request.workspaceID == "workspace-1")
        #expect(request.surfaceID == "terminal-2")
        #expect(store.workspaces.first?.terminals.map(\.id.rawValue) == ["terminal-1"])
        #expect(store.paneRackSnapshot(for: workspace.id)?.panes.first?.tabs.map(\.id.rawValue) == ["terminal-1"])

        await sender.failLastTerminal()
        let result = await closeTask.value
        switch result {
        case .failure(.lastTerminal(let message)):
            #expect(message == "The workspace's last terminal can't be closed")
        default:
            Issue.record("Expected last_terminal failure")
        }
        #expect(store.workspaces.first?.terminals.map(\.id.rawValue) == ["terminal-1", "terminal-2"])
        #expect(store.paneRackSnapshot(for: workspace.id)?.panes.first?.tabs.map(\.id.rawValue)
            == ["terminal-1", "terminal-2"])
        #expect(store.connectionError != nil)
    }
}
