import Bonsplit
import Foundation
import Testing
@testable import CmuxPanes

@MainActor
struct SessionLayoutRestoreTests {
    @Test func restoresNestedLayoutAndSelectedTabsWithoutCreatingLivePanels() throws {
        let controller = BonsplitController()
        let welcomeTabs = controller.allPaneIds.flatMap { controller.tabs(inPane: $0).map(\.id) }
        let codec = SessionSplitContainerLayoutCodec(controller: controller)
        let ids = (0..<4).map { _ in UUID() }
        var tabs: [UUID: TabID] = [:]
        for id in ids { tabs[id] = try #require(controller.createTab(title: id.uuidString)) }
        for tab in welcomeTabs { _ = controller.closeTab(tab) }
        let leaf: ([UUID], UUID, Bool) -> SessionWorkspaceLayoutSnapshot = {
            .pane(.init(panelIds: $0, selectedPanelId: $1, isFullWidthTabMode: $2))
        }
        let saved = SessionWorkspaceLayoutSnapshot.split(.init(
            orientation: .horizontal, dividerPosition: 0.3,
            first: leaf([ids[0]], ids[0], false),
            second: .split(.init(
                orientation: .vertical, dividerPosition: 0.7,
                first: leaf([ids[1], ids[2]], ids[2], true),
                second: leaf([ids[3]], ids[3], false)
            ))
        ))
        #expect(codec.restoreExistingLayout(saved, panelIDMap: [:], tabIDForPanelID: { tabs[$0] }))
        let panelForTab = Dictionary(uniqueKeysWithValues: tabs.map { ($0.value, $0.key) })
        #expect(codec.snapshot { panelForTab[$0] } == saved)
        #expect(controller.allPaneIds.flatMap { controller.tabs(inPane: $0) }.count == 4)
        #expect(controller.allPaneIds.flatMap { controller.tabs(inPane: $0) }.allSatisfy { $0.kind != "restoring" })
    }

    @Test func newerTabsRejectSavedLayoutBeforeAnyMutation() throws {
        let controller = BonsplitController()
        let welcomeTabs = controller.allPaneIds.flatMap { controller.tabs(inPane: $0).map(\.id) }
        let codec = SessionSplitContainerLayoutCodec(controller: controller)
        let original = try #require(controller.createTab(title: "original"))
        for tab in welcomeTabs { _ = controller.closeTab(tab) }
        let originalID = UUID()
        let saved = codec.snapshot { $0 == original ? originalID : nil }
        let otherPane = try #require(controller.splitPane(orientation: .vertical, withTab: .init(title: "new")))
        let current = controller.treeSnapshot()
        #expect(!codec.restoreExistingLayout(saved, panelIDMap: [:], tabIDForPanelID: { $0 == originalID ? original : nil }))
        #expect(controller.treeSnapshot() == current)
        #expect(controller.tabs(inPane: otherPane).count == 1)
    }

    @Test func remappingPreservesPersistedWireShapeAndLegacyDefaults() throws {
        let old = UUID(), new = UUID()
        let json = """
        {"type":"split","split":{"orientation":"vertical","dividerPosition":0.37,
        "first":{"type":"pane","pane":{"panelIds":["\(old)"],"selectedPanelId":"\(old)"}},
        "second":{"type":"pane","pane":{"panelIds":[],"isFullWidthTabMode":true}}}}
        """
        let layout = try JSONDecoder().decode(SessionWorkspaceLayoutSnapshot.self, from: Data(json.utf8))
        let remapped = layout.remappingPanelIDs([old: new])
        guard case .split(let split) = remapped, case .pane(let first) = split.first else {
            Issue.record("Expected nested layout")
            return
        }
        #expect(first.panelIds == [new])
        #expect(first.selectedPanelId == new)
        #expect(first.isFullWidthTabMode == nil)
        #expect(split.dividerPosition == 0.37)
        let data = try JSONEncoder().encode(remapped)
        #expect(try JSONDecoder().decode(SessionWorkspaceLayoutSnapshot.self, from: data) == remapped)
        #expect(layout.remappingPanelIDs([UUID(): UUID()]) == layout)
    }
}
