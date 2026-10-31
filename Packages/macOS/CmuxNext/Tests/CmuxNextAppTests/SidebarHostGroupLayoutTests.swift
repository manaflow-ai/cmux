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

/// The plan that marks or unmarks a host's section (remote-groups-DESIGN.md slices 4 and 5).
struct SidebarDocHostGroupPlanTests {
    private func records(hostGroup: Bool?) -> SidebarDocRecords {
        guard let hostGroup else { return SidebarDocRecords() }
        var section = SidebarDocSection(id: "sec_m_mini", kind: .machine(session: "mini"))
        section.hostGroup = hostGroup
        return SidebarDocRecords(revision: 1, sections: ["sec_m_mini": section])
    }

    @Test func removingAGroupClearsTheFlagAndNothingElse() throws {
        let ops = SidebarDocHostGroupPlan(session: "mini", records: records(hostGroup: true), on: false).ops
        let op = try #require(ops.first)
        #expect(ops.count == 1)
        #expect(op["op"] as? String == "section.update")
        #expect((op["patch"] as? [String: Any])?["host_group"] as? Bool == false)
    }

    @Test func removingWhatIsNotAGroupDoesNothing() {
        #expect(SidebarDocHostGroupPlan(session: "mini", records: records(hostGroup: false), on: false).ops.isEmpty)
        #expect(SidebarDocHostGroupPlan(session: "mini", records: records(hostGroup: nil), on: false).ops.isEmpty)
    }
}

/// `cmux workspace group create --remote HOST --name N` names the remote group: the mark also sets the
/// section's title, and a remote group that already exists is renamed (the header shows the name).
struct SidebarDocHostGroupPlanTitleTests {
    @Test func aNewRemoteGroupTakesItsName() throws {
        let ops = SidebarDocHostGroupPlan(session: "mini", records: SidebarDocRecords(), title: "Build Mini").ops
        let section = try #require(ops.first?["section"] as? [String: Any])
        #expect(section["title"] as? String == "Build Mini")
        #expect(section["host_group"] as? Bool == true)
    }

    @Test func anExistingSectionIsMarkedAndRenamedInOneUpdate() throws {
        let section = SidebarDocSection(id: "sec_m_mini", kind: .machine(session: "mini"))
        let records = SidebarDocRecords(revision: 1, sections: ["sec_m_mini": section])
        let ops = SidebarDocHostGroupPlan(session: "mini", records: records, title: "Build Mini").ops
        #expect(ops.count == 1)
        let patch = try #require(ops.first?["patch"] as? [String: Any])
        #expect(patch["host_group"] as? Bool == true)
        #expect(patch["title"] as? String == "Build Mini")
    }

    @Test func aRemoteGroupThatExistsIsOnlyRenamed() throws {
        var section = SidebarDocSection(id: "sec_m_mini", kind: .machine(session: "mini"))
        section.hostGroup = true
        let records = SidebarDocRecords(revision: 1, sections: ["sec_m_mini": section])
        let patch = try #require(SidebarDocHostGroupPlan(session: "mini", records: records, title: "Build Mini").ops.first?["patch"] as? [String: Any])
        #expect(patch["title"] as? String == "Build Mini")
        #expect(patch["host_group"] == nil)
        #expect(SidebarDocHostGroupPlan(session: "mini", records: records, title: nil).ops.isEmpty)
    }
}
