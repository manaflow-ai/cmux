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
    private static func store(cwd: String, name: String = "workspace-1") -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, title: "", cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])]))
        return store
    }

    /// The front tab's label as the auto name gives an idle shell: its folder's last component, only while nobody named
    /// the workspace (`WorkspaceAutoName.label`).
    private static func folderLabel(_ workspace: WorkspaceModel, _ tab: TabModel, _: TabModel?) -> SidebarMapping.PageFace? {
        .init(title: workspace.isUnnamed ? tab.cwd.map { String($0.split(separator: "/").last ?? "") } : nil, favicon: nil)
    }

    private static func title(cwd: String, machine: SidebarMachine, name: String = "workspace-1") throws -> String {
        let section = try #require(SidebarMapping.shared.sections(store(cwd: cwd, name: name).sidebarSections, machine: machine,
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
        #expect(WorkspaceRowContent(ws, preferences: preferences, machine: "dev-vm · Paused").detail == "Paused · ~")
        #expect(WorkspaceRowContent(ws, preferences: preferences, machine: "build-vm").detail == "build-vm · ~")
    }
}
