import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A remote group (remote-groups-DESIGN.md slice 4) is a host's machine section the person made with
/// New Remote Group: it keeps its header, with the host's name and status, even when the sidebar is
/// one list (`sidebar.groupByComputer` off). Another computer's section in one list keeps no header,
/// as before (cx-mdo0).
@MainActor struct SidebarHostGroupLayoutTests {
    private func section(_ name: String, kind: SidebarMachine.Kind, hostGroup: Bool) -> SidebarSection {
        var section = SidebarSection(kind: .machine(SidebarMachine(id: MachineID(name), name: name, kind: kind)),
                                     nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("\(name)-ws"), title: "\(name) ws"))])
        section.isHostGroup = hostGroup
        return section
    }

    private func headers(_ sections: [SidebarSection]) -> [SectionID] {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .section(id) = row.key { id } else { nil }
        }
    }

    @Test func aRemoteGroupKeepsItsHeaderInOneList() {
        let sections = [section("local", kind: .local, hostGroup: false), section("mini", kind: .server, hostGroup: true)]
        #expect(headers(sections) == [.machine(MachineID("mini"))])
    }

    @Test func anotherComputerInOneListStillHasNoHeader() {
        let sections = [section("local", kind: .local, hostGroup: false), section("vm", kind: .ssh, hostGroup: false)]
        #expect(headers(sections).isEmpty)
    }

    @Test func theDocumentMarksItsRemoteGroups() throws {
        let json = #"{"revision":3,"sections":[{"id":"sec_m_mini","kind":{"type":"machine","session_id":"mini"},"scroll":"flow","host_group":true},{"id":"sec_m_vm","kind":{"type":"machine","session_id":"vm"},"scroll":"flow"}],"items":[]}"#
        let records = try SidebarDocRecords(document: Data(json.utf8))
        #expect(records.sections["sec_m_mini"]?.hostGroup == true)
        #expect(records.sections["sec_m_vm"]?.hostGroup == false)
    }
}
