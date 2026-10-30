import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-29, on the Cloud rows at the bottom of the sidebar: "why is there all this weird stuff at the bottom of
/// the sidebar". An unnamed Cloud workspace whose shell idles at its account's home (`/home/cmux`) read "cmux", its
/// home folder's name, on every machine. It reads as its computer instead; this Mac's rows keep their names.
@MainActor struct SidebarRemoteHomeTitleTests {
    /// A workspace with the daemon's default name and one idle shell in `cwd`.
    /// `tabName`: the person's own name for the tab; `tabTitle`, its title; `kind`, a chat or a terminal.
    private static func store(cwd: String, name: String = "workspace-1", tabName: String? = nil, tabTitle: String = "",
                              kind: TabKind = .pty) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: kind, name: tabName, title: tabTitle, cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])]))
        return store
    }

    /// The front tab's label as the auto name gives an idle shell: its folder's last component, only while nobody named
    /// the workspace (`WorkspaceAutoName.label`).
    /// A tab the person named, or a chat with its own title, gives that instead (`NewWorkspaceName.forTab`).
    private static func folderLabel(_ workspace: WorkspaceModel, _ tab: TabModel, _: TabModel?) -> SidebarMapping.PageFace? {
        let own = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? (tab.kind == .conversation ? tab.displayTitle : nil)
        return .init(title: workspace.isUnnamed ? own ?? tab.cwd.map { String($0.split(separator: "/").last ?? "") } : nil, favicon: nil)
    }

    private static func title(cwd: String, machine: SidebarMachine, name: String = "workspace-1", tabName: String? = nil,
                              tabTitle: String = "", kind: TabKind = .pty) throws -> String {
        let store = store(cwd: cwd, name: name, tabName: tabName, tabTitle: tabTitle, kind: kind)
        let section = try #require(SidebarMapping.shared.sections(store.sidebarSections, machine: machine,
                                                                   pageFace: folderLabel).first)
        return try #require(section.workspaces.first).title
    }

    private static let cloud = SidebarMachine(id: MachineID("vm-1"), name: "dev-vm", kind: .cloud)

    @Test func aCloudShellAtItsHomeReadsAsItsMachine() throws {
        #expect(try Self.title(cwd: "/home/cmux", machine: Self.cloud) == "dev-vm")
        #expect(try Self.title(cwd: "/Users/dev", machine: SidebarMachine(id: MachineID("mini"), name: "mini", kind: .ssh)) == "mini")
    }

    @Test func aCloudShellInAProjectKeepsTheProjectName() throws {
        #expect(try Self.title(cwd: "/home/cmux/app", machine: Self.cloud) == "app")
    }

    /// Only an idle shell's folder is no name: a tab the person named, or a chat titled, the same word as the home
    /// folder keeps it.
    @Test func aTabNamedLikeTheHomeFolderKeepsItsName() throws {
        #expect(try Self.title(cwd: "/home/dev", machine: Self.cloud, tabName: "dev") == "dev")
        #expect(try Self.title(cwd: "/home/dev", machine: Self.cloud, tabTitle: "dev", kind: .conversation) == "dev")
    }

    @Test func aNamedCloudWorkspaceKeepsItsName() throws {
        #expect(try Self.title(cwd: "/home/cmux", machine: Self.cloud, name: "deploy") == "deploy")
    }

    @Test func thisMacsShellAtHomeIsUnchanged() throws {
        #expect(try Self.title(cwd: "/Users/leo", machine: SidebarMachine(id: .local, name: "This Mac", kind: .local)) == "leo")
    }

    /// A row titled by its computer does not say the computer again on its second line; its status stays.
    @Test func aRowTitledByItsMachineDoesNotRepeatIt() {
        let ws = SidebarWorkspace(id: WorkspaceID("w"), title: "dev-vm", directory: "~")
        let preferences = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: []))
        #expect(WorkspaceRowContent(ws, preferences: preferences, machine: "dev-vm").detail == "~")
        #expect(WorkspaceRowContent(ws, preferences: preferences, machine: SidebarMachineLabel(name: "dev-vm", status: "Paused")).detail == "Paused · ~")
        #expect(WorkspaceRowContent(ws, preferences: preferences, machine: "build-vm").detail == "build-vm · ~")
    }

    /// The second line the one-list sidebar gives a Cloud row titled `title` on `machine` (status `status`), normal
    /// rows and expanded ones (`meta`).
    private static func secondLines(title: String, machine name: String, status: String? = nil) -> (normal: String?, expanded: String?) {
        let machine = SidebarMachine(id: MachineID("vm"), name: name, kind: .cloud)
        let ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: machine.id, title: title, directory: "~")
        let mac = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        let section = SidebarSection(kind: .machine(machine), nodes: [.workspace(ws)])
        var o = SidebarModel(sections: [mac, section]).listOptions()
        o.flattensMachines = true
        o.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: []))
        if let status { o.machineStatusLabels[machine.id] = status }
        let normal = o.rowContent(ws, machine: SidebarLayout.machineLabel(section, options: o)).detail
        o.expanded = true
        return (normal, o.rowContent(ws, machine: SidebarLayout.machineLabel(section, options: o)).meta)
    }

    /// Only the machine's whole name is dropped: a title that is the start of a name holding the separator says
    /// nothing about the rest of it (`dev-vm` on `dev-vm · staging` read `staging`).
    @Test func aTitleThatStartsTheMachinesNameKeepsTheName() {
        let lines = Self.secondLines(title: "dev-vm", machine: "dev-vm · staging")
        #expect(lines.normal == "dev-vm · staging · ~")
        #expect(lines.expanded == "dev-vm · staging")
        let paused = Self.secondLines(title: "dev-vm", machine: "dev-vm · staging", status: "Paused")
        #expect(paused.normal == "dev-vm · staging · Paused · ~")
        #expect(paused.expanded == "dev-vm · staging · Paused")
    }

    @Test func aRowTitledByAMachineNameWithTheSeparatorDropsOnlyThatName() {
        let lines = Self.secondLines(title: "dev-vm · staging", machine: "dev-vm · staging", status: "Paused")
        #expect(lines.normal == "Paused · ~")
        #expect(lines.expanded == "Paused")
        let idle = Self.secondLines(title: "dev-vm · staging", machine: "dev-vm · staging")
        #expect(idle.normal == "~")
        #expect(idle.expanded == nil)
    }
}
