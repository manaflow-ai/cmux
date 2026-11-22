import AppKit
import Testing
@testable import CmuxNextSidebar

/// Saved, placeholder and live rows (snapshot-first launch): live rows
/// replace saved ones in place, with the same row views and no motion, and
/// a placeholder is a passive tonal bar.
@MainActor @Suite struct SidebarRowStateTests {
    func sections(_ state: SidebarRowState, ids: [String] = ["w0", "w1", "w2"]) -> [SidebarSection] {
        let rows = ids.map { SidebarWorkspace(id: WorkspaceID($0), title: $0, rowState: state) }
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                               nodes: rows.map(SidebarNode.workspace))]
    }

    func makeSidebar(_ sections: [SidebarSection]) -> SidebarView {
        let view = SidebarView(model: SidebarModel(sections: sections))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return view
    }

    @Test func liveRowsReplaceSavedRowsInPlaceWithoutMotion() throws {
        let saved = sections(.stale)
        let view = makeSidebar(saved)
        let before = try #require(view.list.rowViews[.workspace(id("w1"))])
        let live = sections(.live)
        #expect(!SidebarView.animatesReload(from: saved, to: live))
        view.model.sections = live
        view.list.reload(animated: SidebarView.animatesReload(from: saved, to: live))
        let after = try #require(view.list.rowViews[.workspace(id("w1"))])
        #expect(after === before)
        let target = view.list.frame(for: try #require(view.list.displayed.row(for: .workspace(id("w1")))))
        #expect(after.frame == target)
        #expect(after.alphaValue == 1)
    }

    @Test func placeholdersTurningLiveDoNotAnimateButLiveChangesStillDo() {
        #expect(!SidebarView.animatesReload(from: sections(.placeholder), to: sections(.live)))
        #expect(!SidebarView.animatesReload(from: nil, to: sections(.stale)))
        #expect(SidebarView.animatesReload(from: sections(.live), to: sections(.live, ids: ["w0", "w2"])))
    }

    @Test func aPlaceholderRowIsAPassiveBar() throws {
        let view = makeSidebar(sections(.placeholder))
        let row = try #require(view.list.rowViews[.workspace(id("w0"))] as? WorkspaceRowView)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        #expect(row.title.isHidden)
        #expect(row.closeButton.isHidden)
        #expect(!row.isAccessibilityElement())
        #expect(row.isShowingPlaceholder)
    }

    /// A live section above a connecting one that shows placeholders.
    func mixed() -> [SidebarSection] {
        let live = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                  nodes: [.workspace(SidebarWorkspace(id: id("w0"), title: "w0"))])
        let cloud = MachineID("cloud-1")
        let placeholders = (0..<3).map { SidebarWorkspace(id: id("placeholder:cloud-1:\($0)"), machineID: cloud, title: "", rowState: .placeholder) }
        return [live, SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud, status: .connecting)),
                                     nodes: placeholders.map(SidebarNode.workspace))]
    }

    @Test func arrowKeysNeverLandOnAPlaceholder() {
        let view = makeSidebar(mixed())
        let model = view.model
        var selected: [WorkspaceID] = []
        model.onIntent = { if case let .select(id) = $0 { selected.append(id) } }
        #expect(view.list.visibleWorkspaceOrder == [id("w0")])
        model.click(id("w0"))
        model.moveActive(by: 1, extending: false, visibleOrder: view.list.visibleWorkspaceOrder)
        model.moveActive(by: 1, extending: true, visibleOrder: view.list.visibleWorkspaceOrder)
        // Even given an order that lists placeholders, Shift+Down stays put.
        model.moveActive(by: 1, extending: true, visibleOrder: [id("w0"), id("placeholder:cloud-1:0")])
        #expect(model.selection == [id("w0")])
        #expect(model.activeWorkspaceID == id("w0"))
        #expect(selected.allSatisfy { !$0.rawValue.hasPrefix("placeholder:") })
    }

    @Test func clickingAPlaceholderSendsNothing() {
        let model = SidebarModel(sections: sections(.placeholder))
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        model.click(id("w0"))
        model.toggleSelection(id("w1"))
        #expect(intents.isEmpty)
        #expect(model.activeWorkspaceID == nil)
    }
}
