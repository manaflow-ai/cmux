@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextRemote
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextWorkspaceNaming
import Foundation
import Testing

/// First-run findings row 19 (clean macOS 26 VM, user `admin`): the first terminal idled at the home folder, so its
/// workspace read "admin", the person's login name. An unnamed workspace whose shell idles at this Mac's home reads
/// "Terminal", as a Cloud machine's does (#36283); a folder under home, a title the shell or program set, or an SSH
/// computer's home keeps its own name. The rows come from a daemon store through the sidebar mapping, and the label
/// from the auto-name rule the app runs (`NewWorkspaceName.forTab`).
@MainActor struct HomeShellLoginNameTests {
    private static let home = "/Users/admin"

    /// A workspace with the daemon's default name and one idle shell in `cwd`, titled `title`.
    private static func store(cwd: String, title: String = "") -> DaemonStore {
        let store = DaemonStore()
        let tab = TabSnapshot(surface: 1, title: title, cwd: cwd)
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        return store
    }

    /// The row title of that workspace on `machine`, labelled by the auto-name rule while nobody named it.
    private static func rowTitle(_ store: DaemonStore, machine: SidebarMachine) -> [String] {
        let face: (WorkspaceModel, TabModel, TabModel?) -> SidebarMapping.PageFace? = { workspace, tab, _ in
            let input = NewWorkspaceName.Tab(kind: .terminal, userName: tab.name, title: tab.titleText, pageTitle: nil, url: nil, cwd: tab.cwd)
            return .init(title: workspace.isUnnamed ? NewWorkspaceName.forTab(input) : nil)
        }
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: machine, pageFace: face, terminalTitle: "Terminal")
        return sections.flatMap(\.workspaces).map(\.title)
    }

    private static let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private static let ssh = SidebarMachine(id: MachineID("ssh-mini"), name: "mini", kind: .ssh)

    @Test func aShellAtThisMacsHomeNeverReadsTheLoginName() {
        for title in ["", "zsh", "-zsh", Self.home] {
            let titles = Self.rowTitle(Self.store(cwd: Self.home, title: title), machine: Self.mac)
            #expect(titles == ["Terminal"], "titled \"\(title)\": never \"admin\"")
        }
    }

    @Test func aFolderUnderHomeOrAShellTitleKeepsItsName() {
        #expect(Self.rowTitle(Self.store(cwd: Self.home + "/site"), machine: Self.mac) == ["site"])
        #expect(Self.rowTitle(Self.store(cwd: Self.home, title: "vim notes.md"), machine: Self.mac) == ["vim notes.md"])
    }

    @Test func anSSHComputersHomeKeepsItsFolder() {
        #expect(Self.rowTitle(Self.store(cwd: Self.home), machine: Self.ssh) == ["admin"])
    }

    /// The app's titlebar, palette and pinned tiles read the same rule by machine id.
    @Test func theAppsWiringNamesThisMacAndCloudButNotSSHOrServers() {
        #expect(MachineRegistry.homeNamesAccount(MachineRegistry.localID))
        #expect(MachineRegistry.homeNamesAccount("vm-7f3a"))
        #expect(!MachineRegistry.homeNamesAccount(SSHHost.machineIDPrefix + "mini"))
        #expect(!MachineRegistry.homeNamesAccount(ServerReach.machineIDPrefix + "box"))
    }
}
