import Bonsplit
import CMUXMobileCore
import Testing
@testable import CmuxPanes

@MainActor
@Suite struct MobileWorkspaceLayoutMapperTests {
    @Test func mapsRealBonsplitArrangementAndPaneLocalTabOrder() throws {
        let controller = BonsplitController(configuration: BonsplitConfiguration(
            dividerPositionRange: 0...1
        ))
        let leftPane = try #require(controller.allPaneIds.first)
        let leftFirst = try #require(controller.createTab(title: "Shell", inPane: leftPane))
        let leftSecond = try #require(controller.createTab(title: "Tests", inPane: leftPane))
        let rightPane = try #require(controller.splitPane(
            leftPane,
            orientation: .horizontal,
            initialDividerPosition: 0.4
        ))
        let rightTab = try #require(controller.createTab(title: "Docs", inPane: rightPane))
        controller.selectTab(leftSecond)

        let tab = { (id: String, name: String, kind: MobileWorkspaceTabKind) in
            MobileWorkspaceTab(
                id: id,
                name: name,
                kind: kind,
                isActive: false,
                isReady: true
            )
        }
        let layout = MobileWorkspaceLayoutMapper().layout(
            workspaceID: "workspace-1",
            tree: controller.treeSnapshot(),
            activePaneID: controller.focusedPaneId?.id.uuidString,
            tabsBySurfaceID: [
                leftFirst.uuid.uuidString: tab("terminal-1", "Shell", .terminal),
                leftSecond.uuid.uuidString: tab("terminal-2", "Tests", .terminal),
                rightTab.uuid.uuidString: tab("browser-1", "Docs", .browser),
            ]
        )

        #expect(layout.workspaceID == "workspace-1")
        #expect(layout.activePaneID == leftPane.id.uuidString)
        guard case let .split(root) = layout.root else {
            Issue.record("Expected split root")
            return
        }
        #expect(root.orientation == .horizontal)
        #expect(abs(root.ratio - 0.4) < 0.000_1)
        guard case let .pane(left) = root.first,
              case let .pane(right) = root.second else {
            Issue.record("Expected two pane leaves")
            return
        }
        #expect(left.id == leftPane.id.uuidString)
        #expect(left.frame == MobileWorkspacePaneFrame(x: 0, y: 0, width: 0.4, height: 1))
        #expect(left.tabs.map(\.id) == ["terminal-1", "terminal-2"])
        #expect(left.tabs.map(\.isActive) == [false, true])
        #expect(right.id == rightPane.id.uuidString)
        #expect(right.frame == MobileWorkspacePaneFrame(x: 0.4, y: 0, width: 0.6, height: 1))
        #expect(right.tabs.map(\.id) == ["browser-1"])
        #expect(right.tabs.first?.kind == .browser)
    }
}
