import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobilePaneLayoutDecodeTests {
    @Test func memberwiseWorkspaceProjectionRetainsSharedLayout() throws {
        let sharedLayout = MobileWorkspaceLayout(
            version: 21,
            focusedPaneID: "pane-1",
            root: .pane(
                MobileWorkspaceLayoutPane(
                    id: "pane-1",
                    selectedSurfaceID: "surface-1",
                    surfaces: [
                        MobileWorkspaceLayoutSurface(
                            id: "surface-1",
                            type: "terminal",
                            title: "Shell"
                        )
                    ]
                )
            )
        )
        let remote = MobileSyncWorkspaceListResponse.Workspace(
            id: "workspace-1",
            windowID: "window-1",
            title: "Projected",
            currentDirectory: nil,
            isSelected: true,
            isPinned: false,
            groupID: nil,
            preview: nil,
            previewAt: nil,
            lastActivityAt: 1,
            hasUnread: false,
            terminals: [],
            layout: sharedLayout
        )

        #expect(remote.layout == sharedLayout)
        let projected = MobileWorkspacePreview(remote: remote)
        let layout = try #require(projected.layout)
        #expect(layout.version == 21)
        #expect(layout.focusedPaneID == "pane-1")
        #expect(layout.orderedPanes.map(\.id) == ["pane-1"])
        #expect(layout.orderedPanes.first?.selectedSurfaceID == "surface-1")
    }

    @Test func decodesAndMapsFullNestedLayout() throws {
        let data = Data("""
        {
          "workspaces": [
            {
              "id": "workspace-1",
              "window_id": "window-1",
              "title": "Pane Layout",
              "current_directory": "/tmp/project",
              "is_selected": true,
              "terminals": [
                {
                  "id": "surface-terminal",
                  "title": "Agent",
                  "current_directory": "/tmp/project",
                  "is_focused": true,
                  "is_ready": true
                }
              ],
              "layout": {
                "version": 12,
                "focused_pane_id": "pane-tabs",
                "root": {
                  "kind": "split",
                  "id": "split-root",
                  "orientation": "horizontal",
                  "ratio": 0.01,
                  "first": {
                    "kind": "pane",
                    "id": "pane-tabs",
                    "selected_surface_id": "surface-browser",
                    "surfaces": [
                      {"id": "surface-terminal", "type": "terminal", "title": "Agent"},
                      {"id": "surface-browser", "type": "browser", "title": "Preview"}
                    ]
                  },
                  "second": {
                    "kind": "split",
                    "id": "split-nested",
                    "orientation": "vertical",
                    "ratio": 1.2,
                    "first": {
                      "kind": "pane",
                      "id": "pane-docs",
                      "selected_surface_id": "surface-markdown",
                      "surfaces": [
                        {"id": "surface-markdown", "type": "markdown", "title": "README"}
                      ]
                    },
                    "second": {
                      "kind": "pane",
                      "id": "pane-tools",
                      "selected_surface_id": "surface-file",
                      "surfaces": [
                        {"id": "surface-file", "type": "filepreview", "title": "Diff"},
                        {"id": "surface-sidebar-tool", "type": "rightSidebarTool", "title": "Tool"},
                        {"id": "surface-custom-sidebar", "type": "customSidebar", "title": "Custom"},
                        {"id": "surface-agent", "type": "agentSession", "title": "Agent Session"},
                        {"id": "surface-project", "type": "project", "title": "Project"},
                        {"id": "surface-extension", "type": "extensionBrowser", "title": "Extension"},
                        {"id": "surface-todo", "type": "workspaceTodo", "title": "Todos"},
                        {"id": "surface-cloud", "type": "cloudVMLoading", "title": "Starting VM"},
                        {"id": "surface-future", "type": "futurePanel", "title": "Future"}
                      ]
                    }
                  }
                }
              }
            }
          ]
        }
        """.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(data)
        let remoteWorkspace = try #require(response.workspaces.first)
        let workspace = MobileWorkspacePreview(remote: remoteWorkspace)
        let layout = try #require(workspace.layout)

        #expect(layout.version == 12)
        #expect(layout.focusedPaneID == "pane-tabs")
        #expect(layout.orderedPanes.map(\.id) == ["pane-tabs", "pane-docs", "pane-tools"])
        #expect(layout.pane(containing: "surface-browser")?.selectedSurfaceID == "surface-browser")

        guard case let .split(rootSplit) = layout.root else {
            Issue.record("Expected a root split")
            return
        }
        #expect(rootSplit.id == "split-root")
        #expect(rootSplit.orientation == .horizontal)
        #expect(rootSplit.ratio == 0.05)
        guard case let .split(nestedSplit) = rootSplit.second else {
            Issue.record("Expected the root's second child to be a split")
            return
        }
        #expect(nestedSplit.orientation == .vertical)
        #expect(nestedSplit.ratio == 0.95)

        let tabTypes = try #require(layout.orderedPanes.first).surfaces.map(\.type)
        #expect(tabTypes == [.terminal, .browser])
        let toolTypes = try #require(layout.orderedPanes.last).surfaces.map(\.type)
        #expect(toolTypes == [
            .filepreview,
            .rightSidebarTool,
            .customSidebar,
            .agentSession,
            .project,
            .extensionBrowser,
            .workspaceTodo,
            .cloudVMLoading,
            .other("futurePanel"),
        ])
    }

    @Test func missingAndMalformedLayoutsDoNotFailWorkspaceList() throws {
        let data = Data("""
        {
          "workspaces": [
            {
              "id": "workspace-old",
              "title": "Older Mac",
              "is_selected": true,
              "terminals": []
            },
            {
              "id": "workspace-garbage-kind",
              "title": "Future Kind",
              "is_selected": false,
              "terminals": [],
              "layout": {
                "version": 13,
                "focused_pane_id": null,
                "root": {"kind": "grid", "id": "unsupported"}
              }
            },
            {
              "id": "workspace-malformed-pane",
              "title": "Malformed Pane",
              "is_selected": false,
              "terminals": [],
              "layout": {
                "version": 14,
                "focused_pane_id": null,
                "root": {
                  "kind": "pane",
                  "id": "pane-without-surfaces",
                  "selected_surface_id": null
                }
              }
            }
          ]
        }
        """.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(data)

        #expect(response.workspaces.count == 3)
        #expect(response.workspaces.allSatisfy { $0.layout == nil })
        #expect(response.workspaces.map { MobileWorkspacePreview(remote: $0).layout }.allSatisfy { $0 == nil })
        #expect(response.workspaces.map(\.id) == [
            "workspace-old",
            "workspace-garbage-kind",
            "workspace-malformed-pane",
        ])
        #expect(response.workspaces.map(\.title) == ["Older Mac", "Future Kind", "Malformed Pane"])
        #expect(response.workspaces.map(\.isSelected) == [true, false, false])
        #expect(response.workspaces.allSatisfy { $0.terminals.isEmpty })
    }
}
