import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite
struct PaneRackCreateTests {
    @Test func createTargetsPaneAndSelectsCreatedTerminal() async throws {
        let sender = ControllablePaneRackRequestSender()
        let workspace = MobileWorkspacePreview(
            id: "workspace-1",
            name: "Agents",
            terminals: [
                MobileTerminalPreview(id: "terminal-1", name: "one", paneID: "pane-a"),
            ],
            panes: [
                MobilePanePreview(
                    id: "pane-a",
                    tabIDs: ["terminal-1"],
                    selectedTabID: "terminal-1",
                    isFocused: true,
                    rect: MobilePaneNormalizedRect(x: 0, y: 0, w: 1, h: 1)
                ),
            ]
        )
        let defaults = UserDefaults(suiteName: "PaneRackCreateTests-\(UUID().uuidString)")!
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

        let createTask = Task { @MainActor in
            await store.createTab(inPane: "pane-a", workspaceID: workspace.id)
        }
        let request = await sender.nextRequest()
        #expect(request.method == "terminal.create")
        #expect(request.workspaceID == "workspace-1")
        #expect(request.paneID == "pane-a")
        let response = """
        {
          "created_terminal_id": "terminal-2",
          "workspaces": [{
            "id": "workspace-1",
            "title": "Agents",
            "is_selected": true,
            "terminals": [
              {"id": "terminal-1", "title": "one", "is_focused": false, "pane_id": "pane-a"},
              {"id": "terminal-2", "title": "two", "is_focused": false, "pane_id": "pane-a"}
            ],
            "panes": [{
              "id": "pane-a",
              "tab_ids": ["terminal-1", "terminal-2"],
              "selected_tab_id": "terminal-1",
              "is_focused": true,
              "rect": {"x": 0, "y": 0, "w": 1, "h": 1}
            }]
          }]
        }
        """
        await sender.succeed(with: Data(response.utf8))
        let result = await createTask.value
        if case .failure(let failure) = result {
            Issue.record("Create failed: \(failure)")
        }
        #expect(store.selectedTerminalID?.rawValue == "terminal-2")
        #expect(store.paneRackSnapshot(for: workspace.id)?.panes.first?.selectedTabID?.rawValue == "terminal-2")
    }
}
