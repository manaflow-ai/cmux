import Testing
@testable import CmuxNextSidebar

/// cx-zdh8: in the one list (`sidebar.groupByComputer` off) an empty
/// computer shows nothing, so an SSH machine whose connect failed (no
/// workspaces yet) had no row and the failure was invisible. A machine that
/// needs the person (sign-in failed, unreachable, cmux-tui missing or too
/// old) keeps its own header in the one list: its name, the red status and
/// the badge, the tooltip with the SSH error, and its right-click menu.
struct MachineErrorRowTests {
    static let ssh = MachineID("ssh-host")
    static let sshSection = SectionID.machine(ssh)

    static func sections(_ status: SidebarMachine.Status, nodes: [SidebarNode] = []) -> [SidebarSection] {
        [
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(w("a"))]),
            SidebarSection(kind: .machine(SidebarMachine(id: ssh, name: "build-box", kind: .ssh, status: status,
                                                         detail: "SSH sign-in failed: Permission denied (publickey).")),
                           nodes: nodes),
        ]
    }

    static func rows(_ sections: [SidebarSection]) -> [SidebarRow] {
        var o = SidebarLayoutOptions()
        o.showsSoleMachineHeader = true
        o.flattensMachines = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows
    }

    @Test(arguments: [SidebarMachine.Status.authFailed, .unreachable, .installRequired, .updateRequired])
    func aMachineThatNeedsThePersonKeepsItsHeaderInOneList(_ status: SidebarMachine.Status) throws {
        let rows = Self.rows(Self.sections(status))
        let header = try #require(rows.first { $0.key == .section(Self.sshSection) }, "no row for the failed machine")
        #expect(!header.titlesProjects, "the header names the machine, not Projects")
        #expect(!rows.contains { $0.key == .emptySection(Self.sshSection) }, "the header alone says it; no empty drop row")
        #expect(rows.first { $0.key == .section(local) }?.titlesProjects == true, "the list keeps its one Projects header")
    }

    @Test(arguments: [SidebarMachine.Status.connecting, .offline, .connected])
    func aQuietEmptyMachineStillShowsNothing(_ status: SidebarMachine.Status) {
        let keys = Self.rows(Self.sections(status)).map(\.key)
        #expect(!keys.contains(.section(Self.sshSection)))
        #expect(!keys.contains(.emptySection(Self.sshSection)))
    }

    @Test func aFailedMachineWithWorkspacesListsThemUnderItsHeader() {
        let keys = Self.rows(Self.sections(.authFailed, nodes: [.workspace(w("r", Self.ssh))])).map(\.key)
        #expect(keys == [.section(local), .workspace(id("a")), .section(Self.sshSection), .workspace(id("r"))])
    }

    @Test func aCollapsedListStillShowsTheFailure() {
        var sections = Self.sections(.authFailed, nodes: [.workspace(w("r", Self.ssh))])
        sections[0].isCollapsed = true
        #expect(Self.rows(sections).map(\.key) == [.section(local), .section(Self.sshSection)])
    }
}
