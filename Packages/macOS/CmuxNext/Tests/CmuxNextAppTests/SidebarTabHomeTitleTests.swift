import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-29, on the Cloud rows at the bottom of the sidebar with workspace tabs listed: "why is there all this
/// weird stuff at the bottom of the sidebar". A Cloud shell nobody titled listed its tab as `/home/cmux`, the raw
/// home of a computer whose row already names it; this Mac's home was already `~`, another computer's never was.
@MainActor @Suite(.serialized)
struct SidebarTabHomeTitleTests {
    /// One workspace whose one terminal tab sits in `cwd`, titled `title` (empty: untitled, as a fresh shell is).
    private static func tab(cwd: String, title: String = "", machine: MachineID) -> SidebarTab? {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, title: title, cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "dev", screens: [screen])]))
        guard let workspace = store.workspaces.first else { return nil }
        return SidebarMapping.shared.row(workspace, machine: machine,
                                         tabTitle: { TabItemMapping.shared.title($0, fallbackTitle: "Terminal") }).tabs.first
    }

    private static func name(_ tab: SidebarTab?) -> String? {
        tab.map { SidebarTabLine.make($0, look: .detail, terminalName: "Terminal").name }
    }

    private static let cloud = MachineID("vm-1")

    @Test func aCloudShellAtItsHomeIsATerminal() {
        let tab = Self.tab(cwd: "/home/cmux", machine: Self.cloud)
        #expect(tab?.title == "~")
        // Its row already names the machine and the folder, so the tab line says what runs there.
        #expect(Self.name(tab) == "Terminal")
    }

    @Test func aCloudShellTitledByItsHomeIsATerminal() {
        #expect(Self.name(Self.tab(cwd: "/home/cmux", title: "/home/cmux", machine: Self.cloud)) == "Terminal")
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
}
