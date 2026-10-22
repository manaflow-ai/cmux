@testable import CmuxNextSidebar
import Foundation
import Testing

/// One list is chronological across computers (remote-groups-per-machine-DESIGN.md R3): the rows of
/// every computer without a header interleave newest first by when each workspace joined the
/// document, each computer keeps its own order, and every row keeps its own section and index so a
/// drop, a fold and a row update still name the right place.
@MainActor struct SidebarOneListMergeTests {
    private func ws(_ id: String, _ machine: String, _ created: UInt64?) -> SidebarNode {
        var ws = SidebarWorkspace(id: WorkspaceID(id), machineID: MachineID(machine), title: id)
        ws.createdMs = created
        return .workspace(ws)
    }

    private func section(_ machine: String, _ kind: SidebarMachine.Kind, _ nodes: [SidebarNode], hostGroup: Bool = false) -> SidebarSection {
        var section = SidebarSection(kind: .machine(SidebarMachine(id: MachineID(machine), name: machine, kind: kind)), nodes: nodes)
        section.isHostGroup = hostGroup
        return section
    }

    private func layout(_ sections: [SidebarSection], gap: DropPosition? = nil) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        options.gap = gap
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    private func order(_ layout: SidebarLayout) -> [String] {
        layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
    }

    @Test func computersInterleaveNewestFirst() {
        let sections = [section("local", .local, [ws("L2", "local", 40), ws("L1", "local", 10)]),
                        section("mini", .ssh, [ws("M1", "mini", 30)])]
        let made = layout(sections)
        #expect(order(made) == ["L2", "M1", "L1"])
        let mini = made.row(for: .workspace(WorkspaceID("M1")))
        #expect(mini?.section == .machine(MachineID("mini")))
        #expect(mini?.siblingIndex == 0)
        #expect(made.row(for: .workspace(WorkspaceID("L1")))?.siblingIndex == 1)
    }

    @Test func eachComputerKeepsItsOwnOrder() {
        // The person moved the older La above Lb on this Mac: the merge never swaps them.
        let sections = [section("local", .local, [ws("La", "local", 10), ws("Lb", "local", 50)]),
                        section("mini", .ssh, [ws("M", "mini", 30)])]
        #expect(order(layout(sections)) == ["M", "La", "Lb"])
    }

    @Test func rowsWithoutATimeKeepTodaysOrder() {
        let sections = [section("local", .local, [ws("L1", "local", nil), ws("L2", "local", nil)]),
                        section("mini", .ssh, [ws("M1", "mini", nil)])]
        #expect(order(layout(sections)) == ["L1", "L2", "M1"])
    }

    @Test func aShownRemoteGroupIsNotMerged() {
        let sections = [section("local", .local, [ws("L1", "local", 10)]),
                        section("mini", .ssh, [ws("M1", "mini", 30)], hostGroup: true)]
        #expect(order(layout(sections)) == ["L1", "M1"])
    }

    @Test func aDropGapOpensAtItsComputersPlace() {
        let sections = [section("local", .local, [ws("L2", "local", 40), ws("L1", "local", 10)]),
                        section("mini", .ssh, [ws("M1", "mini", 30)])]
        // After M1 (the mini's index 1): between M1 and L1 in the merged list.
        let made = layout(sections, gap: DropPosition(section: .machine(MachineID("mini")), index: 1))
        let gapY = try? #require(made.gapY)
        let m1 = made.row(for: .workspace(WorkspaceID("M1")))!, l1 = made.row(for: .workspace(WorkspaceID("L1")))!
        #expect(gapY.map { $0 >= m1.maxY && $0 < l1.y } == true)
    }

    @Test func theDocumentCarriesEachWorkspacesTime() throws {
        let json = #"{"revision":3,"sections":[{"id":"sec_m_mini","kind":{"type":"machine","session_id":"mini"},"scroll":"flow"}],"items":[{"id":"itm_w_mini_ws1","section":"sec_m_mini","order":"a","body":{"type":"workspace","ref":{"session_id":"mini","workspace_id":"ws1","created_ms":1700000000000}}}]}"#
        let records = try SidebarDocRecords(document: Data(json.utf8))
        #expect(records.items["itm_w_mini_ws1"]?.createdMs == 1_700_000_000_000)
    }
}
