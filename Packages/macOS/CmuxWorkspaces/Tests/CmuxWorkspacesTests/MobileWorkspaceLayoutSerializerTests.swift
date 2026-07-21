import Bonsplit
import CMUXMobileCore
import Testing

@testable import CmuxWorkspaces

struct MobileWorkspaceLayoutSerializerTests {
    private let frame = PixelRect(x: 0, y: 0, width: 100, height: 100)

    @Test func serializesSpatialOrderAndPanelMetadata() throws {
        let tree = ExternalTreeNode.split(
            ExternalSplitNode(
                id: "split-root",
                orientation: "horizontal",
                dividerPosition: 0.4,
                first: .pane(
                    ExternalPaneNode(
                        id: "pane-left",
                        frame: frame,
                        tabs: [
                            ExternalTab(id: "tab-shell", title: "Fallback shell"),
                            ExternalTab(id: "tab-preview", title: "Fallback preview"),
                        ],
                        selectedTabId: "tab-preview"
                    )
                ),
                second: .pane(
                    ExternalPaneNode(
                        id: "pane-right",
                        frame: frame,
                        tabs: [ExternalTab(id: "tab-docs", title: "Docs")],
                        selectedTabId: "tab-docs"
                    )
                )
            )
        )
        let serializer = MobileWorkspaceLayoutSerializer()

        #expect(serializer.tabs(in: tree).map(\.id) == ["tab-shell", "tab-preview", "tab-docs"])
        #expect(serializer.paneTopology(in: tree) == [
            MobileWorkspacePaneTopology(
                id: "pane-left",
                surfaceIDs: ["tab-shell", "tab-preview"],
                selectedSurfaceID: "tab-preview"
            ),
            MobileWorkspacePaneTopology(
                id: "pane-right",
                surfaceIDs: ["tab-docs"],
                selectedSurfaceID: "tab-docs"
            ),
        ])

        let layout = serializer.layout(
            tree: tree,
            version: 9,
            focusedPaneID: "pane-right",
            surfacesByTabID: [
                "tab-shell": MobileWorkspaceLayoutSurfaceMetadata(
                    id: "panel-shell",
                    type: "terminal",
                    title: "Renamed shell"
                ),
                "tab-preview": MobileWorkspaceLayoutSurfaceMetadata(
                    id: "panel-preview",
                    type: "browser",
                    title: "Preview"
                ),
            ]
        )

        #expect(layout.version == 9)
        #expect(layout.focusedPaneID == "pane-right")
        guard case let .split(split) = layout.root else {
            Issue.record("Expected a root split")
            return
        }
        #expect(split.orientation == .horizontal)
        #expect(split.ratio == 0.4)
        guard case let .pane(left) = split.first,
              case let .pane(right) = split.second else {
            Issue.record("Expected two pane children")
            return
        }
        #expect(left.selectedSurfaceID == "panel-preview")
        #expect(left.surfaces == [
            MobileWorkspaceLayoutSurface(id: "panel-shell", type: "terminal", title: "Renamed shell"),
            MobileWorkspaceLayoutSurface(id: "panel-preview", type: "browser", title: "Preview"),
        ])
        #expect(right.selectedSurfaceID == "tab-docs")
        #expect(right.surfaces == [
            MobileWorkspaceLayoutSurface(id: "tab-docs", type: "terminal", title: "Docs")
        ])
    }
}
