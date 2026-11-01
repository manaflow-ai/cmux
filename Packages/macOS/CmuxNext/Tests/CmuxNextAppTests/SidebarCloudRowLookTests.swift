import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-30, of a Cloud machine drawn as a header with a green dot over a row with a cloud icon, "cmux" and a
/// second line: "when the fuck did i say i wanted a second fucking line and a green dot and a fuckign ICON ON THE
/// LEFT!??!!?!?!? JUST DEPICT IT SIMILARLY TO EVERYTHING ELSE". A Cloud section's header is a name, a chevron and a +;
/// its rows are one line, their title; an idle shell at the machine's home reads "Terminal". The machine mark stays as
/// base draws it, in the trailing status column (#29833, Leo 2026-11-01: "I HATE THAT THEY'RE ON THE LEFT"). This
/// Mac's and an SSH computer's rows are as they were.
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

    @Test func aCloudRowIsOneLineWithNoLeadingIcon() throws {
        let rows = rows([mac, cloud])
        let vm = try #require(rows[WorkspaceID("build-vm-ws")]), local = try #require(rows[WorkspaceID("This Mac-ws")])
        let content = try #require(vm.content)
        // The machine mark is base's trailing one (#29833), not a leading icon.
        #expect(content.machine?.name == "build-vm")
        #expect(content.icon == nil, "no icon before the title")
        #expect(content.detail == nil, "no second line")
        #expect(vm.height == local.height, "as tall as this Mac's one-line row")
        // VoiceOver still says the computer.
        #expect(content.machineLabel == "build-vm")
    }

    /// Outside its machine's header (Pinned, a custom section) the mark still names the machine, and VoiceOver says it.
    @Test func aPinnedCloudRowKeepsItsMark() throws {
        let pinned = SidebarRowSection(kind: .custom(SidebarCustomSection(id: "pinned", title: "Pinned", showsTitle: true)),
                                       nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("pinned-vm-ws"), machineID: cloud.id,
                                                                           title: "deploy", directory: "~"))])
        let model = SidebarModel(sections: [pinned] + [mac, cloud].map(section))
        let layout = SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
        let row = try #require(layout.rows.first { $0.key == .workspace(WorkspaceID("pinned-vm-ws")) })
        let content = try #require(row.content)
        #expect(content.machine?.name == "build-vm")
        let label = WorkspaceRowView.accessibilityText(SidebarWorkspace(id: WorkspaceID("pinned-vm-ws"), machineID: cloud.id, title: "deploy"),
                                                       content: content, tabCount: nil, presence: [])
        #expect(label.contains("build-vm"))
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
    private static func store(cwd: String, name: String = "workspace-1", tabName: String? = nil, tabTitle: String = "") -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, name: tabName, title: tabTitle, cwd: cwd)])
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

    private static func title(cwd: String, machine: SidebarMachine, name: String = "workspace-1", tabName: String? = nil,
                              tabTitle: String = "") throws -> String {
        let section = try #require(SidebarMapping.shared.sections(store(cwd: cwd, name: name, tabName: tabName, tabTitle: tabTitle).sidebarSections,
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

    /// A title the shell or a program set (OSC 0/2) is the tab's own word, even when it reads like the home folder; a
    /// title that is only the folder's path is the shell saying where it is (review of #28051 at 28c330e6).
    @Test func aCloudShellWithItsOwnTitleIsNotTerminal() throws {
        #expect(try Self.title(cwd: "/home/cmux", machine: cloud, tabTitle: "cmux") != "Terminal")
        #expect(try Self.title(cwd: "/home/cmux", machine: cloud, tabTitle: "/home/cmux") == "Terminal")
    }

    @Test func anSSHOrLocalShellAtHomeIsUnchanged() throws {
        #expect(try Self.title(cwd: "/home/dev", machine: ssh) == "dev")
        #expect(try Self.title(cwd: "/Users/leo", machine: mac) == "leo")
    }
}
