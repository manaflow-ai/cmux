import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-29, on the Cloud rows at the bottom of the sidebar: "why is there all this weird stuff at the bottom of
/// the sidebar". A Cloud shell nobody titled named its tab `/home/cmux`, the raw home of a computer whose row already
/// names it; this Mac's home was already `~`, another computer's never was.
@MainActor @Suite(.serialized)
struct SidebarTabHomeTitleTests {
    /// One workspace whose one terminal tab sits in `cwd`, titled `title` (empty: untitled, as a fresh shell is).
    /// `name` is the person's own name for the tab (a rename).
    /// `agent`: a terminal agent (Claude Code, Codex in a shell) its hooks report on the tab.
    private static func tab(cwd: String, title: String = "", name: String? = nil, agent: String? = nil,
                            machine: MachineID) -> SidebarTab? {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, name: name, title: title, cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "dev", screens: [screen])]))
        guard let workspace = store.workspaces.first else { return nil }
        if let agent { workspace.screens.flatMap(\.panes).flatMap(\.tabs).first?.setAgent(AgentStatus(surface: 1, state: .working, agent: agent)) }
        return SidebarMapping.shared.row(workspace, machine: machine,
                                         tabTitle: { TabItemMapping.shared.title($0, fallbackTitle: "Terminal") }).tabs.first
    }

    private static let cloud = MachineID("vm-1")

    @Test func aCloudShellAtItsHomeReadsAsHome() {
        #expect(Self.tab(cwd: "/home/cmux", machine: Self.cloud)?.title == "~")
    }

    @Test func aCloudShellTitledByItsHomeReadsAsHome() {
        #expect(Self.tab(cwd: "/home/cmux", title: "/home/cmux", machine: Self.cloud)?.title == "~")
    }

    @Test func aCloudShellInAProjectSaysItsFolderAsItsPromptDoes() {
        #expect(Self.tab(cwd: "/home/cmux/app", machine: Self.cloud)?.title == "~/app")
    }

    @Test func thisMacsShellTitledByItsRawHomeReadsAsHome() {
        let home = NSHomeDirectory()
        #expect(Self.tab(cwd: home, title: home, machine: .local)?.title == "~")
    }

    @Test func aTitleThatIsNotAFolderIsUnchanged() {
        #expect(Self.tab(cwd: "/home/cmux", title: "vim notes.md", machine: Self.cloud)?.title == "vim notes.md")
        #expect(Self.tab(cwd: "/srv/app", title: "/srv/app", machine: .local)?.title == "/srv/app")
    }

    @Test func aTitleNamingItsFolderWithATrailingSlashIsStillItsFolder() {
        #expect(Self.tab(cwd: "/home/cmux", title: "/home/cmux/", machine: Self.cloud)?.title == "~")
    }

    /// Only a title that is the tab's own folder is shortened: a path a program titles the tab with says something else.
    @Test func aTitleNamingAnotherFolderIsUnchanged() {
        #expect(Self.tab(cwd: "/home/cmux/other", title: "/home/cmux/project", machine: Self.cloud)?.title == "/home/cmux/project")
        let home = NSHomeDirectory()
        #expect(Self.tab(cwd: home + "/other", title: home + "/project", machine: .local)?.title == home + "/project")
    }

    /// A name the person gave the tab is theirs, as typed, even when it is a folder.
    @Test func aRenamedTabKeepsItsName() {
        #expect(Self.tab(cwd: "/home/cmux/other", name: "/home/cmux/project", machine: Self.cloud)?.title == "/home/cmux/project")
        #expect(Self.tab(cwd: "/home/cmux", name: "/home/cmux", machine: Self.cloud)?.title == "/home/cmux")
    }

    /// A terminal running an agent is the agent's tab, whatever its shell titled it: it keeps its title.
    @Test func aTerminalAgentsTabKeepsItsTitle() {
        #expect(Self.tab(cwd: "/home/cmux", title: "/home/cmux", agent: "claude", machine: Self.cloud)?.title == "/home/cmux")
        #expect(Self.tab(cwd: "/home/cmux/app", agent: "codex", machine: Self.cloud)?.title == "/home/cmux/app")
    }
}
