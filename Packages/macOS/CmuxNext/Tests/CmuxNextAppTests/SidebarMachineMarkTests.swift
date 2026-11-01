import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Machine identity: while the sidebar lists more than one machine, a workspace row on another
/// machine marks it (its glyph, one neutral colour, in the trailing column), so rows on different machines tell apart. This Mac's
/// rows are marked only with `sidebar.showLocalMachine` (Leo 2026-10-20: another machine is the
/// news). One machine: no mark.
@MainActor @Suite(.serialized) struct SidebarMachineMarkTests {
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

    /// The row's label names the machine once (VoiceOver read "gpu-box" twice after #22763). A compact
    /// row has no second line of its own (Leo 2026-10-30: "remove the second line"), so its mark names it.
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
        #expect(oneList.detail == nil, "a compact row drew a second line naming its computer")
        #expect(names(label(oneList)) == 1)
        var grouped = o
        grouped.flattensMachines = false
        let underHeader = grouped.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: grouped))
        #expect(names(label(underHeader)) == 1)
        var minimal = o
        minimal.minimal = true
        #expect(names(label(minimal.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: minimal)))) == 1)
    }

    /// Review of #28510 at 5f1d588f (P1): a machine that cannot connect has its status in the one-list label
    /// (`gpu-box · Failed to start`). With no second line to draw it, the row's accessibility label says it.
    @Test func aFailedMachinesStatusIsStillSpoken() throws {
        let model = SidebarModel(sections: [mac, vm].map(section))
        var o = model.listOptions()
        o.machineStatusLabels[vm.id] = "Failed to start"
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: vm.id, title: "w", directory: "~/code/app")
        let content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: o))
        #expect(content.detail == nil, "fixture: no second line draws it")
        let text = WorkspaceRowView.accessibilityText(ws, content: content, tabCount: nil, presence: [])
        #expect(text.contains("gpu-box · Failed to start"), "VoiceOver lost the failed machine's status: \(text)")
        #expect(text.components(separatedBy: "gpu-box").count - 1 == 1, "the computer was named twice: \(text)")
    }

    /// Review of #28510 at 58ee6d24 (P1): every row mode says the failed machine's status, and a row that draws no
    /// mark (only that one machine listed, so no marks) still names the computer.
    @Test(arguments: ["compact", "minimal", "tabs", "expanded", "unmarked"])
    func everyRowModeSpeaksAFailedMachinesStatus(_ mode: String) throws {
        let model = SidebarModel(sections: [mac, vm].map(section))
        var o = model.listOptions()
        o.machineStatusLabels[vm.id] = "Failed to start"
        switch mode {
        case "minimal": o.minimal = true
        case "tabs": o.workspacesAsTabs = true
        case "expanded": o.expanded = true
        case "unmarked": o.machines = [:]
        default: break
        }
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: vm.id, title: "w", directory: "~/code/app")
        let content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section(vm), options: o))
        if mode == "unmarked" { #expect(content.machine == nil, "fixture: no mark drawn") }
        let text = WorkspaceRowView.accessibilityText(ws, content: content, tabCount: nil, presence: [])
        #expect(text.contains("gpu-box · Failed to start"), "\(mode): VoiceOver lost the failed machine's status: \(text)")
        #expect(text.components(separatedBy: "gpu-box").count - 1 == 1, "\(mode): the computer was named twice: \(text)")
    }

    /// Review of #28510 at 4acab8c2: the detail holds the facts the person turned on, so it proves nothing about
    /// the machine. A branch named after the machine, or starting with its name, never hides the machine or its status.
    @Test(arguments: [("dev", "develop", nil), ("dev", "dev", "Failed to start")] as [(String, String, String?)])
    func aBranchNamedLikeTheMachineHidesNeitherTheMachineNorItsStatus(_ name: String, _ branch: String, _ status: String?) throws {
        let dev = SidebarMachine(id: MachineID("dev"), name: name, kind: .ssh)
        let model = SidebarModel(sections: [mac, dev].map(section))
        var o = model.listOptions()
        o.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.branch])))
        if let status { o.machineStatusLabels[dev.id] = status }
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: dev.id, title: "w", branch: branch)
        let content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section(dev), options: o))
        try #require(content.detail == branch, "fixture: the branch is the row's second line")
        let text = WorkspaceRowView.accessibilityText(ws, content: content, tabCount: nil, presence: [])
        let label = status.map { "\(name) · \($0)" } ?? name
        #expect(text.hasSuffix(", \(label)") || text.contains(", \(label),"), "the machine or its status went unsaid: \(text)")
    }

    /// A machine whose name holds the row's separator (`gpu · box`) is still named once.
    @Test func aNameWithTheSeparatorIsNamedOnce() throws {
        let dotted = SidebarMachine(id: MachineID("dotted"), name: "gpu · box", kind: .ssh)
        let o = SidebarModel(sections: [mac, dotted].map(section)).listOptions()
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: dotted.id, title: "w", directory: "~/code/app")
        let content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section(dotted), options: o))
        #expect(content.machine != nil)
        let text = WorkspaceRowView.accessibilityText(ws, content: content, tabCount: nil, presence: [])
        #expect(text.components(separatedBy: "gpu · box").count - 1 == 1, "\(text)")
    }

    @Test func oneListCloudRowsShowPausedConnectingAndReconnecting() {
        let states: [(SidebarMachine.Status, String)] = [
            (.paused, Strings.statusPaused),
            (.connecting, Strings.statusConnecting),
            (.reconnecting, Strings.statusReconnecting),
        ]
        for (status, label) in states {
            let cloud = SidebarMachine(id: MachineID("cloud-\(label)"), name: "cloud", kind: .cloud, status: status)
            let cloudSection = SidebarSection(kind: .machine(cloud), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("cloud-ws"), title: "ws"))])
            let options = SidebarModel(sections: [section(mac), cloudSection]).listOptions()
            #expect(SidebarLayout.machineLabel(cloudSection, options: options) == "cloud · \(label)")
        }
    }

    @Test func oneMachineDrawsNoMark() {
        #expect(marks(showsLocalMachine: true, [mac]).isEmpty)
    }

    /// The realized rows of a sidebar listing this Mac and two other machines, each with one workspace.
    private static func machineRows() throws -> [String: WorkspaceRowView] {
        let machines = [
            SidebarMachine(id: .local, name: "This Mac", kind: .local),
            SidebarMachine(id: MachineID("cloud-a"), name: "cloud-a", kind: .cloud),
            SidebarMachine(id: MachineID("gpu-box"), name: "gpu-box", kind: .ssh),
        ]
        let model = SidebarModel(sections: machines.map { m in
            SidebarSection(kind: .machine(m), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-\(m.name)"), machineID: m.id,
                                                                                  title: "a workspace named at length \(m.name)"))])
        })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        var rows: [String: WorkspaceRowView] = [:]
        for m in machines {
            let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("ws-\(m.name)"))] as? WorkspaceRowView)
            row.layoutSubtreeIfNeeded()
            row.updateLayer()
            rows[m.name] = row
        }
        return rows
    }

    /// Leo 2026-11-01, on a small tinted cloud before each Cloud row's name: "I HATE HOW SMALL THEY ARE I HATE THAT THEY'RE
    /// ON THE LEFT I HATE THAT THEY'RE ON THE BOTTOM". The mark sits in the trailing column, right of the title's text, in a
    /// status mark's box (the spinner's and the warning triangle's), centered on the row's middle.
    @Test func theMarkSitsInTheTrailingColumnAtAStatusMarksSizeOnTheRowsMiddle() throws {
        let rows = try Self.machineRows()
        for name in ["cloud-a", "gpu-box"] {
            let row = try #require(rows[name])
            try #require(!row.machineMark.isHidden, "\(name): the row on another machine shows its mark")
            let mark = row.machineMark.frame
            let side = SidebarStyle.statusGlyphSize
            #expect(mark.size == NSSize(width: side, height: side), "\(name): mark box \(mark.size), status mark box \(side)")
            #expect(mark.width >= SidebarStyle.indicatorSize, "\(name): mark \(mark.width) smaller than the row's marks")
            #expect(mark.minX >= row.title.frame.maxX - 0.5, "\(name): mark at \(mark.minX) is not right of the title (ends \(row.title.frame.maxX))")
            #expect(row.title.frame.minX < mark.minX, "\(name): title still starts after the mark")
            #expect(abs(mark.midY - row.bounds.midY) < 0.5, "\(name): mark center y \(mark.midY), row middle \(row.bounds.midY)")
            // With no status, the mark takes the column the spinner and triangle center on.
            let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)
            #expect(abs(mark.midX - column) < 0.5, "\(name): mark center x \(mark.midX), trailing column \(column)")
        }
        #expect(rows["This Mac"]?.machineMark.isHidden == true, "this Mac's row stays unmarked by default")
    }

    /// One colour for every machine: a neutral label colour, never the machine's own (MachineColor) tint.
    @Test func everyMachinesMarkHasTheSameNeutralColour() throws {
        let rows = try Self.machineRows()
        let cloud = try #require(rows["cloud-a"]?.machineMark.contentTintColor)
        let ssh = try #require(rows["gpu-box"]?.machineMark.contentTintColor)
        #expect(cloud == ssh, "two machines drew two colours: \(cloud) and \(ssh)")
        #expect(cloud != MachineColor(name: "cloud-a").color, "the mark still takes its machine's tint")
    }

    /// Hovering the row shows its controls over the trailing column; the mark gives way to them as the spinner does.
    @Test func theMarkGivesWayToTheHoverControls() throws {
        let row = try #require(try Self.machineRows()["cloud-a"])
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let controls: [NSView] = [row.closeButton, row.moreButton].filter { !$0.isHidden && $0.alphaValue > 0 }
        try #require(!controls.isEmpty, "the hover controls show")
        let mark = row.machineMark
        let overlaps = controls.contains { $0.frame.intersects(mark.frame) }
        #expect(!overlaps || mark.alphaValue == 0, "the mark \(mark.frame) draws under a hover control (alpha \(mark.alphaValue))")
    }
}
