import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// An agent chat names its sidebar row over an idle shell beside it (Leo, 2026-10-28: "we don't want to
/// just be seeing these bare terminals. It's weird to have that be the thing that's showing. I'd rather just
/// see the other thing instead of that, you know, tilde."). A shell doing work still names the row.
@MainActor
struct SidebarChatFrontTests {
    private static let host = "install:chat-front"

    /// A shell titled `shell` in `cwd`, focused last, beside an agent chat (unless `chat` is false).
    private static func workspace(shell: String, cwd: String = NSHomeDirectory(), chat: Bool = true) throws -> WorkspaceModel {
        var tabs = [TabSnapshot(surface: 1, terminalID: "10", kind: .pty, title: shell, cwd: cwd)]
        if chat {
            var snapshot = TabSnapshot(surface: 2, kind: .conversation, title: "about:blank")
            snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s1", harness: "claude"))
            tabs.append(snapshot)
        }
        let panes = [PaneSnapshot(id: 1, focusedAt: 2, tabs: [tabs[0]])] + (chat ? [PaneSnapshot(id: 2, focusedAt: 1, tabs: [tabs[1]])] : [])
        let layout: LayoutNode = chat ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2)) : .leaf(1)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-7",
                                                                        screens: [ScreenSnapshot(id: 1, layout: layout, panes: panes)])]))
        return try #require(store.workspaces.first)
    }

    /// The row as the app maps it: a chat names it "Fix login", a terminal its own title.
    private static func row(_ workspace: WorkspaceModel, newTabPages: Set<String> = []) -> SidebarWorkspace {
        SidebarMapping.shared.row(workspace, machine: .local, newTabPages: newTabPages, pageFace: { _, tab, _ in
            .init(title: tab.agentSession != nil ? "Fix login" : tab.titleText)
        })
    }

    private static func tab(_ workspace: WorkspaceModel, _ kind: TabKind) -> TabModel? {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.kind == kind }
    }

    @Test(arguments: ["~", "zsh", "-zsh", ""])
    func anIdleShellAtHomeLeavesTheRowToTheChat(shell: String) throws {
        let workspace = try Self.workspace(shell: shell)
        let row = Self.row(workspace)
        #expect(row.title == "Fix login")
        #expect(row.kind == .harness)
        #expect(row.directory == nil, "the idle shell's \"~\" still labels the row")
        // The window's selection is untouched: the shell stays the focused tab.
        #expect(row.focusedTab == Self.tab(workspace, .pty).map { TabID($0.id) })
    }

    @Test func aShellDoingWorkStillNamesTheRow() throws {
        let row = Self.row(try Self.workspace(shell: "npm test"))
        #expect(row.title == "npm test")
        #expect(row.process == "npm test")
        #expect(row.directory == "~")
    }

    /// A command running in a shell still titled "~" (no title from the program) is work.
    @Test func aRunningCommandUnderABareTitleStillNamesTheRow() throws {
        let workspace = try Self.workspace(shell: "~")
        let shell = try #require(Self.tab(workspace, .pty))
        shell.applyState(nil, progress: nil, commandSinceMs: 1_000)
        let row = Self.row(workspace)
        #expect(row.title == "~")
        #expect(row.directory == "~")
    }

    @Test func anIdleShellInAProjectKeepsItsFolder() throws {
        let row = Self.row(try Self.workspace(shell: "zsh", cwd: "/tmp/project"))
        #expect(row.title == "Fix login")
        #expect(row.directory == "/tmp/project")
    }

    @Test func withoutAChatTheShellNamesTheRow() throws {
        let row = Self.row(try Self.workspace(shell: "~", chat: false))
        #expect(row.title == "~")
        #expect(row.directory == "~")
    }

    @Test func aNewTabPageInFrontLeavesTheRowToTheChat() throws {
        let workspace = try Self.workspace(shell: "npm test")
        let shell = try #require(Self.tab(workspace, .pty))
        #expect(Self.row(workspace, newTabPages: [shell.id]).title == "Fix login")
    }

    /// The titlebar (`WorkspaceAutoNameReader.titlebarName`) reads the same tab.
    @Test func theTitlebarReadsTheChatToo() throws {
        let workspace = try Self.workspace(shell: "~")
        let mapping = SidebarMapping.shared
        let front = mapping.frontTab(workspace, selectedTab: { _ in nil })
        #expect(front?.kind == .pty)
        #expect(mapping.labelTab(front, workspace.screens.flatMap(\.panes).flatMap(\.tabs))?.agentSession?.session == "s1")
    }
}
