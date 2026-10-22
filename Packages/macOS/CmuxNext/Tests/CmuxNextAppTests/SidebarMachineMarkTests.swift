import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Machine identity: while the sidebar lists more than one machine, a workspace row on another
/// machine marks it (its glyph in its color), so rows on different machines tell apart. This Mac's
/// rows are marked only with `sidebar.showLocalMachine` (Leo 2026-10-20: another machine is the
/// news). One machine: no mark.
@MainActor struct SidebarMachineMarkTests {
    private let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private let vm = SidebarMachine(id: MachineID("vm"), name: "gpu-box", kind: .ssh, icon: .symbol("server.rack"))

    private func section(_ machine: SidebarMachine) -> SidebarSection {
        SidebarSection(kind: .machine(machine),
                       nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("\(machine.name)-ws"), machineID: machine.id, title: "ws"))])
    }

    private func marks(showsLocalMachine: Bool = false, _ machines: [SidebarMachine]) -> [MachineID: SidebarMachineMark] {
        let model = SidebarModel(sections: machines.map(section))
        model.showsLocalMachine = showsLocalMachine
        let o = model.listOptions()
        var marks: [MachineID: SidebarMachineMark] = [:]
        for machine in machines {
            let row = o.rowContent(SidebarWorkspace(id: WorkspaceID("w"), machineID: machine.id, title: "w"), machine: nil)
            marks[machine.id] = row.machine
        }
        return marks
    }

    @Test func anotherMachinesRowsAreMarkedThisMacsAreNot() throws {
        let marks = marks([mac, vm])
        let remote = try #require(marks[vm.id])
        #expect(remote.name == "gpu-box")
        #expect(remote.symbol == "server.rack")
        #expect(marks[mac.id] == nil)
    }

    @Test func theSettingMarksThisMacsRowsToo() throws {
        let local = try #require(marks(showsLocalMachine: true, [mac, vm])[mac.id])
        #expect(local.kindIcon == .machineLocal)
    }

    @Test func anEmojiIconIsTheMachinesMark() throws {
        let box = SidebarMachine(id: MachineID("box"), name: "box", kind: .ssh, icon: .emoji("🦊"))
        let mark = try #require(marks([mac, box])[box.id])
        #expect(mark.emoji == "🦊")
        #expect(mark.symbol == nil)
    }

    /// The row's label names the machine once (VoiceOver read "gpu-box" twice after #22763): the
    /// one-list second line leads with it, so the mark adds nothing; with no such line, the mark names it.
    @Test func theRowsLabelNamesTheMachineOnce() throws {
        let model = SidebarModel(sections: [mac, vm].map(section))
        let o = model.listOptions()
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: vm.id, title: "w", directory: "~/code/app")
        func label(_ content: WorkspaceRowContent) -> String {
            WorkspaceRowView.accessibilityText(ws, content: content, tabCount: nil, presence: [])
        }
        func names(_ text: String) -> Int { text.components(separatedBy: "gpu-box").count - 1 }
        let oneList = o.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: o))
        #expect(oneList.machine != nil)
        #expect(label(oneList).hasPrefix("w, gpu-box · "))
        #expect(names(label(oneList)) == 1)
        var grouped = o
        grouped.flattensMachines = false
        let underHeader = grouped.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: grouped))
        #expect(names(label(underHeader)) == 1)
        var minimal = o
        minimal.minimal = true
        #expect(names(label(minimal.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: minimal)))) == 1)
    }

    /// A machine whose name holds the row's separator (`gpu · box`) is still named once.
    @Test func aNameWithTheSeparatorIsNamedOnce() throws {
        let dotted = SidebarMachine(id: MachineID("dotted"), name: "gpu · box", kind: .ssh)
        let o = SidebarModel(sections: [mac, dotted].map(section)).listOptions()
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: dotted.id, title: "w", directory: "~/code/app")
        let content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section(dotted), options: o))
        #expect(content.machine != nil)
        let text = WorkspaceRowView.accessibilityText(ws, content: content, tabCount: nil, presence: [])
        #expect(text.hasPrefix("w, gpu · box · "))
        #expect(text.components(separatedBy: "gpu · box").count - 1 == 1, "\(text)")
    }

    @Test func oneMachineDrawsNoMark() {
        #expect(marks(showsLocalMachine: true, [mac]).isEmpty)
    }
}
