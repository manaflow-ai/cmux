import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// #21357: a new workspace's row showed no title. A terminal workspace gets no
/// page or agent title, so hiding the daemon's `workspace-N` name left the row
/// blank until the user renamed it.
@MainActor
struct SidebarDefaultWorkspaceNameTests {
    private static func rows(names: [String]) -> [SidebarWorkspace] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: names.enumerated().map { index, name in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\(index + 1)"), name: name)
        }))
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        return sections.flatMap(\.workspaces)
    }

    private static func row(name: String, cwd: String?, machine: MachineID = .local, title: String? = nil,
                            pageTitle: String? = nil) -> SidebarWorkspace {
        let tab = TabSnapshot(surface: 1, kind: pageTitle == nil ? .pty : .browser, cwd: cwd)
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(
            id: 1, key: nil, resourceID: ResourceID(rawValue: "ws-auto"), name: name,
            screens: [screen], title: title
        )]))
        let sections = SidebarMapping.shared.sections(
            store.sidebarSections,
            machine: SidebarMachine(id: machine, name: machine == .local ? "This Mac" : "Remote", kind: machine == .local ? .local : .server),
            pageFace: { _, _ in pageTitle.map { SidebarMapping.PageFace(title: $0) } }
        )
        return sections[0].workspaces[0]
    }

    @Test func aWorkspaceWithTheDaemonDefaultNameShowsIt() {
        #expect(Self.rows(names: ["workspace-1", "workspace-2"]).map(\.title) == ["workspace-1", "workspace-2"])
    }

    @Test func aGeneratedNameUsesTheFirstFolderBasenameForLocalAndRemoteMachines() {
        let local = Self.row(name: "workspace-7", cwd: "/Users/leo/Projects/local-app", machine: .local)
        let remote = Self.row(name: "workspace-8", cwd: "/home/leo/Projects/remote-app", machine: MachineID("remote-1"))
        #expect(local.title == "local-app")
        #expect(remote.title == "remote-app")
    }

    @Test func explicitWorkspaceNamesAndTitlesWinOverTheFolderBasename() {
        let named = Self.row(name: "named", cwd: "/Users/leo/Projects/folder")
        let titled = Self.row(name: "workspace-9", cwd: "/Users/leo/Projects/folder", title: "Pinned")
        #expect(named.title == "named")
        #expect(titled.title == "Pinned")
    }

    @Test func pageTitlesWinOverGeneratedNamesAndFolderBasenames() {
        let row = Self.row(name: "workspace-10", cwd: "/Users/leo/Projects/folder", pageTitle: "Dashboard")
        #expect(row.title == "Dashboard")
    }

    @Test(arguments: ["", "   ", "/", "//", "/tmp/.", "/tmp/.."])
    func blankRootAndDotFoldersKeepTheGeneratedName(path: String) {
        #expect(Self.row(name: "workspace-11", cwd: path).title == "workspace-11")
    }

    @Test func generatedWorkspaceNameDetectionAcceptsOnlyTheDaemonPattern() {
        for name in ["workspace-1", "workspace-42", "workspace-0"] {
            #expect(SidebarMapping.isDefaultWorkspaceName(name), "expected generated name: \(name)")
        }
        for name in ["workspace", "workspace-x", "workspace-1x", "Workspace-1", "workspace-1 "] {
            #expect(!SidebarMapping.isDefaultWorkspaceName(name), "expected explicit name: \(name)")
        }
    }

    @Test func aCreatingRowShowsTheNameItWillHave() {
        let row = SidebarMapping.shared.creatingRow(id: "pending", machine: .local, name: "workspace-3", opensPage: false)
        #expect(row.title == "workspace-3")
    }
}
