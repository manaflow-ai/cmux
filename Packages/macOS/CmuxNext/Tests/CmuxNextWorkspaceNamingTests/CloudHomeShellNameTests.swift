import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextWorkspaceNaming

/// An unnamed Cloud workspace whose shell idles at its home reads "Terminal" in the sidebar (#28051), and its window's
/// titlebar, the palette and the rename prompt name it the same way (`titlebarName`), never the account's home folder,
/// "cmux" (#36283). An SSH computer's or this Mac's workspace keeps its folder everywhere.
@MainActor
struct CloudHomeShellNameTests {
    /// A workspace with the daemon's default name and one idle shell in `cwd`.
    private static func workspace(cwd: String, tabTitle: String = "") throws -> WorkspaceModel {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, title: tabTitle, cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    /// The real reader; `cloud` gives it the title a Cloud machine's home shell takes, as the app's wiring does.
    private static func reader(cloud: Bool) -> WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(
            enabled: { true }, isNewTabPage: { _ in false }, livePage: { _ in nil }, incognitoTitle: { _ in nil },
            terminal: { NewWorkspaceName.Tab(kind: .terminal, userName: $0.name, title: $0.title, pageTitle: nil, url: $0.url, cwd: $0.cwd) },
            turns: AgentTurnStateStore(), hold: WorkspaceAutoNameHold(), homeShellTitle: { _ in cloud ? "Terminal" : nil })
    }

    /// The sidebar row's title and the titlebar's name of one workspace, read through the same reader.
    private static func names(_ workspace: WorkspaceModel, cloud: Bool) -> (row: String, titlebar: String) {
        let reader = Self.reader(cloud: cloud)
        let row = SidebarMapping.shared.row(workspace, machine: MachineID(cloud ? "vm-1" : "ssh-mini"),
                                            pageFace: { workspace, tab, work in .init(title: reader.label(workspace, front: tab, work: work)) },
                                            homeShellTitle: cloud ? "Terminal" : nil)
        return (row.title, reader.titlebarName(workspace) { _ in nil })
    }

    @Test func aCloudHomeShellReadsTerminalInTheTitlebarAsInTheSidebar() throws {
        for title in ["", "zsh", "-bash", "/home/cmux"] {
            let names = Self.names(try Self.workspace(cwd: "/home/cmux", tabTitle: title), cloud: true)
            #expect(names.row == "Terminal", "titled \"\(title)\"")
            #expect(names.titlebar == "Terminal", "titled \"\(title)\": never the account's folder, \"cmux\"")
        }
    }

    @Test func aCloudShellWithItsOwnTitleOrFolderKeepsItEverywhere() throws {
        for (cwd, title, expected) in [("/home/cmux", "deploy", "deploy"), ("/home/cmux/app", "", "app")] {
            let names = Self.names(try Self.workspace(cwd: cwd, tabTitle: title), cloud: true)
            #expect(names.row == expected)
            #expect(names.titlebar == expected)
        }
    }

    @Test func anSSHShellAtHomeKeepsItsFolderEverywhere() throws {
        let names = Self.names(try Self.workspace(cwd: "/home/dev"), cloud: false)
        #expect(names.row == "dev")
        #expect(names.titlebar == "dev")
    }
}
