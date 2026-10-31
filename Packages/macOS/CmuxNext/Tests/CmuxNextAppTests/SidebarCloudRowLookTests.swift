import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-30, of a Cloud machine drawn as a header with a green dot over a row with a cloud icon, "cmux" and a
/// second line: "when the fuck did i say i wanted a second fucking line and a green dot and a fuckign ICON ON THE
/// LEFT!??!!?!?!? JUST DEPICT IT SIMILARLY TO EVERYTHING ELSE". A Cloud section's header is a name, a chevron and a +;
/// its rows are one line, their title, with no mark; an idle shell at the machine's home reads "Terminal". This Mac's
/// and an SSH computer's rows are as they were.
@MainActor struct SidebarCloudRowLookTests {
    private let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private let cloud = SidebarMachine(id: MachineID("vm-1"), name: "build-vm", kind: .cloud)
    private let ssh = SidebarMachine(id: MachineID("mini"), name: "mini", kind: .ssh)

    private func section(_ machine: SidebarMachine) -> SidebarRowSection {
        SidebarRowSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(
            id: WorkspaceID("\(machine.name)-ws"), machineID: machine.id, title: "Terminal", directory: "~"))])
    }

    /// The default one-list sidebar's rows, by workspace.
    private func rows(_ machines: [SidebarMachine]) -> [WorkspaceID: SidebarRow] {
        let model = SidebarModel(sections: machines.map(section))
        let layout = SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
        var rows: [WorkspaceID: SidebarRow] = [:]
        for row in layout.rows { if case let .workspace(id) = row.key { rows[id] = row } }
        return rows
    }

    @Test func aCloudRowIsOneLineWithNoIcon() throws {
        let rows = rows([mac, cloud])
        let vm = try #require(rows[WorkspaceID("build-vm-ws")]), local = try #require(rows[WorkspaceID("This Mac-ws")])
        let content = try #require(vm.content)
        #expect(content.machine == nil, "no cloud mark before the title: the header names the machine")
        #expect(content.icon == nil)
        #expect(content.detail == nil, "no second line")
        #expect(vm.height == local.height, "as tall as this Mac's one-line row")
        // VoiceOver still says the computer.
        #expect(content.machineLabel == "build-vm")
    }

    @Test func anSSHRowKeepsItsMark() throws {
        let row = try #require(rows([mac, ssh])[WorkspaceID("mini-ws")])
        #expect(row.content?.machine?.name == "mini")
    }

    @Test func aConnectedCloudHeaderHasNoDot() {
        #expect(SectionHeaderRowView.tone(cloud, hostGroup: false) == nil)
        var updating = cloud
        updating.status = .updateAvailable
        #expect(SectionHeaderRowView.tone(updating, hostGroup: false) == nil)
    }

    /// A down machine's state is information: its header keeps the mark and the words.
    @Test func aDownCloudHeaderKeepsItsState() {
        var down = cloud
        down.status = .disconnected
        #expect(SectionHeaderRowView.tone(down, hostGroup: false) != nil)
        #expect(SectionHeaderRowView.statusText(.disconnected, hostGroup: false) == "Disconnected")
        down.status = .paused
        #expect(SectionHeaderRowView.tone(down, hostGroup: false) == .quiet)
        #expect(SectionHeaderRowView.tone(ssh, hostGroup: false) == .success, "an SSH computer's header is unchanged")
    }

    // MARK: Title

    /// A workspace with the daemon's default name and one idle shell in `cwd`.
    private static func store(cwd: String, name: String = "workspace-1", tabName: String? = nil) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, name: tabName, title: "", cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])]))
        return store
    }

    /// The front tab's label as the auto name gives it: a tab's own name, else an idle shell's folder, only while
    /// nobody named the workspace (`WorkspaceAutoName.label`).
    private static func folderLabel(_ workspace: WorkspaceModel, _ tab: TabModel, _: TabModel?) -> SidebarMapping.PageFace? {
        let own = tab.name.flatMap { $0.isEmpty ? nil : $0 }
        return .init(title: workspace.isUnnamed ? own ?? tab.cwd.map { String($0.split(separator: "/").last ?? "") } : nil, favicon: nil)
    }

    private static func title(cwd: String, machine: SidebarMachine, name: String = "workspace-1", tabName: String? = nil) throws -> String {
        let section = try #require(SidebarMapping.shared.sections(store(cwd: cwd, name: name, tabName: tabName).sidebarSections,
                                                                   machine: machine, pageFace: folderLabel,
                                                                   terminalTitle: "Terminal").first)
        return try #require(section.workspaces.first).title
    }

    @Test func aCloudShellAtItsHomeReadsTerminal() throws {
        #expect(try Self.title(cwd: "/home/cmux", machine: cloud) == "Terminal", "never the account's home folder, \"cmux\"")
        #expect(try Self.title(cwd: "/home/cmux/", machine: cloud) == "Terminal")
    }

    @Test func aCloudWorkspaceWithANameKeepsIt() throws {
        #expect(try Self.title(cwd: "/home/cmux/app", machine: cloud) == "app")
        #expect(try Self.title(cwd: "/home/cmux", machine: cloud, name: "deploy") == "deploy")
        #expect(try Self.title(cwd: "/home/cmux", machine: cloud, tabName: "cmux") == "cmux", "a tab the person named")
    }

    @Test func anSSHOrLocalShellAtHomeIsUnchanged() throws {
        #expect(try Self.title(cwd: "/home/dev", machine: ssh) == "dev")
        #expect(try Self.title(cwd: "/Users/leo", machine: mac) == "leo")
    }
}
