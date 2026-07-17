import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Decode-path tests for the `layout` field of `mobile.workspace.list`:
/// wire JSON -> `MobileSyncWorkspaceListResponse` -> `MobileWorkspacePreview.paneLayout`.
@Suite struct MobileWorkspaceLayoutDecodeTests {
    private func workspaceJSON(layout: String?) -> Data {
        let layoutField = layout.map { ", \"layout\": \($0)" } ?? ""
        let json = """
        {
          "workspaces": [
            {
              "id": "ws-1",
              "title": "Workspace",
              "is_selected": true,
              "terminals": [
                {"id": "t1", "title": "Agent", "is_focused": true},
                {"id": "t2", "title": "Server", "is_focused": false}
              ]\(layoutField)
            }
          ]
        }
        """
        return Data(json.utf8)
    }

    private let splitLayoutJSON = """
    {
      "type": "split",
      "orientation": "horizontal",
      "ratio": 0.62,
      "first": {
        "type": "pane",
        "pane_id": "pane-a",
        "tabs": [
          {"id": "t1", "kind": "terminal", "title": "Agent"},
          {"id": "b1", "kind": "browser", "title": "Preview"}
        ],
        "selected_tab_id": "t1"
      },
      "second": {
        "type": "pane",
        "pane_id": "pane-b",
        "tabs": [{"id": "t2", "kind": "terminal", "title": "Server"}],
        "selected_tab_id": "t2"
      }
    }
    """

    @Test func layoutDecodesIntoPaneLayoutModel() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(
            workspaceJSON(layout: splitLayoutJSON)
        )
        let preview = MobileWorkspacePreview(remote: try #require(response.workspaces.first))
        let layout = try #require(preview.paneLayout)
        #expect(layout.panes.map(\.id) == ["pane-a", "pane-b"])
        #expect(layout.orderedTabs.map(\.id.rawValue) == ["t1", "b1", "t2"])
        #expect(layout.orderedTabs.map(\.kind) == [.terminal, .browser, .terminal])
        #expect(layout.panes[0].selectedTabID == "t1")
        guard case let .split(orientation, ratio, _, _) = layout.root else {
            Issue.record("expected split root")
            return
        }
        #expect(orientation == .horizontal)
        #expect(abs(ratio - 0.62) < 0.0001)
    }

    @Test func absentLayoutDecodesToNil() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(workspaceJSON(layout: nil))
        let preview = MobileWorkspacePreview(remote: try #require(response.workspaces.first))
        #expect(preview.paneLayout == nil)
    }

    @Test func malformedLayoutDegradesToNilWithoutFailingTheList() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(
            workspaceJSON(layout: "{\"type\": \"mystery\"}")
        )
        let workspace = try #require(response.workspaces.first)
        #expect(workspace.layout == nil)
        #expect(workspace.terminals.count == 2)
    }

    @Test func unknownTabKindDegradesToOther() throws {
        let layoutJSON = """
        {
          "type": "pane",
          "pane_id": "p",
          "tabs": [{"id": "x", "kind": "hologram", "title": "X"}],
          "selected_tab_id": null
        }
        """
        let response = try MobileSyncWorkspaceListResponse.decode(workspaceJSON(layout: layoutJSON))
        let preview = MobileWorkspacePreview(remote: try #require(response.workspaces.first))
        #expect(preview.paneLayout?.orderedTabs.first?.kind == .other)
    }
}
