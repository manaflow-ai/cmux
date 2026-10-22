import AppKit
@testable import CmuxNextSidebar
import CmuxNextIcons
import Foundation
import Testing

/// A remote group's header is a tiny machine icon and the machine's name (remote-groups-per-machine-DESIGN.md
/// R1, Lawrence via Leo 2026-10-21): the icon takes the place of the old status color dot, it is the
/// machine's form (cloud, Mac mini, laptop, desktop Mac, server) unless the person set an icon, and the
/// header says nothing while the machine is connected. Any other state is in words beside the name.
@MainActor @Suite(.serialized) struct RemoteGroupHeaderIconTests {
    private static func header(_ machine: SidebarMachine, hostGroup: Bool = true) -> SectionHeaderRowView {
        var section = SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-\(machine.id.rawValue)"), title: "api")),
        ])
        section.isHostGroup = hostGroup
        let row = SidebarRow(key: .section(section.id), y: 0, height: 28, section: section.id, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 1, groupColor: nil)
        let view = SectionHeaderRowView(key: row.key)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        view.configure(section, row: row)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private static func machine(_ name: String, _ kind: SidebarMachine.Kind, status: SidebarMachine.Status = .connected,
                                icon: WorkspaceIcon? = nil) -> SidebarMachine {
        SidebarMachine(id: MachineID(name), name: name, kind: kind, status: status, icon: icon)
    }

    @Test(arguments: [
        ("fs-vm-12", SidebarMachine.Kind.cloud, SidebarMachineForm.cloud),
        ("cmux-mini-2", .ssh, .macMini),
        ("Lawrence's Mac mini", .server, .macMini),
        ("lawrence-macbook-pro", .ssh, .laptop),
        ("leo-mbp", .ssh, .laptop),
        ("studio", .ssh, .desktop),
        ("linux-box", .ssh, .server),
        ("ubuntu@orb", .server, .server),
        ("This Mac", .local, .thisMac),
    ])
    func aMachineDrawsItsForm(name: String, kind: SidebarMachine.Kind, form: SidebarMachineForm) {
        #expect(SidebarMachineForm(Self.machine(name, kind)) == form, "\(name)")
    }

    @Test func eachFormHasItsOwnIcon() {
        #expect(SidebarMachineForm.cloud.icon == .cloud)
        #expect(SidebarMachineForm.macMini.icon == .machineMac)
        #expect(SidebarMachineForm.laptop.icon == .machineLocal)
        #expect(SidebarMachineForm.desktop.icon == .machine)
        #expect(SidebarMachineForm.server.icon == .machineRemote)
        #expect(SidebarMachineForm.thisMac.icon == .machineLocal)
    }

    /// The form's icon leads the name in place of the dot; no dot draws in any state.
    @Test func theHeaderDrawsTheFormIconAndNoDot() {
        for status: SidebarMachine.Status in [.connected, .connecting, .offline, .unreachable] {
            let view = Self.header(Self.machine("cmux-mini-2", .ssh, status: status))
            #expect(view.leadingGlyph == .machineMac, "\(status)")
            #expect(!view.showsStatusDot, "\(status)")
        }
    }

    /// The person's icon wins over the form, and only one icon draws.
    @Test func theUsersIconReplacesTheForm() {
        let view = Self.header(Self.machine("cmux-mini-2", .ssh, icon: .emoji("🍎")))
        #expect(view.showsMachineIcon)
        #expect(view.leadingGlyph == nil)
    }

    /// Minimal: a connected machine says nothing; every other state is in words, remote group or not.
    @Test func onlyAStateThatIsNotConnectedIsInWords() {
        for hostGroup in [true, false] {
            #expect(SectionHeaderRowView.statusText(.connected, hostGroup: hostGroup) == nil)
            #expect(SectionHeaderRowView.statusText(.offline, hostGroup: hostGroup) == Strings.statusOffline)
            #expect(SectionHeaderRowView.statusText(.connecting, hostGroup: hostGroup) == Strings.statusConnecting)
            #expect(SectionHeaderRowView.statusText(.reconnecting, hostGroup: hostGroup) == Strings.statusReconnecting)
        }
    }

    /// A machine that is not connected dims its icon and name.
    @Test func aMachineThatIsNotConnectedIsDimmed() {
        #expect(!Self.header(Self.machine("cmux-mini-2", .ssh)).isDimmed)
        #expect(Self.header(Self.machine("cmux-mini-2", .ssh, status: .offline)).isDimmed)
    }

    /// The rows under a remote group's header draw no machine mark: the header names the machine.
    /// In one list a row of another computer keeps its mark, drawn as the same form.
    @Test func rowsUnderAHeaderDrawNoMachineMark() {
        func section(_ name: String, kind: SidebarMachine.Kind, hostGroup: Bool) -> SidebarSection {
            var section = SidebarSection(kind: .machine(SidebarMachine(id: MachineID(name), name: name, kind: kind)),
                                         nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("\(name)-ws"), machineID: MachineID(name), title: name))])
            section.isHostGroup = hostGroup
            return section
        }
        let sections = [section("local", kind: .local, hostGroup: false), section("cmux-mini-2", kind: .ssh, hostGroup: true),
                        section("linux-box", kind: .ssh, hostGroup: false)]
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        options.machines = Dictionary(uniqueKeysWithValues: sections.compactMap(\.machine).filter { $0.kind != .local }.map { ($0.id, $0) })
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(WorkspaceID("cmux-mini-2-ws")))?.content?.machine == nil)
        let mark = layout.row(for: .workspace(WorkspaceID("linux-box-ws")))?.content?.machine
        #expect(mark?.kindIcon == .machineRemote)
    }
}
