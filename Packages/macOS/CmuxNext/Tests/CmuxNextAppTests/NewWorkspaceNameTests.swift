import CmuxNextActions
import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

/// R15 (Lawrence 2026-10-02): a workspace made from a dragged or moved tab
/// takes the tab's name. Before: every path left the daemon default
/// "workspace-N".
@Suite struct NewWorkspaceNameTests {
    private typealias T = NewWorkspaceName.Tab

    @Test func aTerminalTakesItsLiveTitle() {
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "vim README.md", cwd: "/Users/a/fun/cmux")) == "vim README.md")
    }

    @Test func theUsersTabNameWins() {
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, userName: "server", title: "npm run dev")) == "server")
        #expect(NewWorkspaceName.forTab(T(kind: .browser, userName: "docs", title: "Docs", pageTitle: "Docs - cmux")) == "docs")
    }

    @Test func aBareShellTitleReadsAsTheDirectory() {
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "zsh", cwd: "/Users/a/fun/cmux")) == "cmux")
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "-bash", cwd: "/Users/a/notes")) == "notes")
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "", cwd: "/Users/a")) == "a")
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "zsh")) == nil)
    }

    @Test func aBrowserTakesItsLivePageTitleThenItsHost() {
        #expect(NewWorkspaceName.forTab(T(kind: .browser, title: "Loading", pageTitle: "Pull requests · cmux", url: "https://github.com/x")) == "Pull requests · cmux")
        #expect(NewWorkspaceName.forTab(T(kind: .browser, title: "GitHub", url: "https://github.com/x")) == "GitHub")
        #expect(NewWorkspaceName.forTab(T(kind: .browser, title: "", url: "https://www.github.com/x")) == "github.com")
        #expect(NewWorkspaceName.forTab(T(kind: .browser, title: "https://github.com/x", url: "https://github.com/x")) == "github.com")
    }

    @Test func aRemoteTerminalTakesItsTitle() {
        #expect(NewWorkspaceName.forTab(T(kind: .remoteTerminal, title: "htop")) == "htop")
    }

    @Test func namesAreTrimmedAndBounded() {
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "  build  ")) == "build")
        let long = String(repeating: "x", count: 200)
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: long))?.count == NewWorkspaceName.maxLength)
        #expect(NewWorkspaceName.forTab(T(kind: .terminal, title: "a\nb")) == "a b")
    }

    @Test func aGroupTakesItsNameThenItsFirstTab() {
        #expect(NewWorkspaceName.forGroup(name: "Review", firstTab: T(kind: .terminal, title: "git")) == "Review")
        #expect(NewWorkspaceName.forGroup(name: "", firstTab: T(kind: .terminal, title: "git log")) == "git log")
        #expect(NewWorkspaceName.forGroup(name: nil, firstTab: nil) == nil)
    }
}

/// The shared path names the workspace: palette and CLI run
/// `palette.moveTabToNewWorkspace`, drag and tear-off call the same
/// `TabMoves.toNewWorkspace`.
@MainActor @Suite(.serialized) struct MoveTabToNewWorkspaceNameTests {
    @Test(arguments: [false, true]) func aTabMovedToANewWorkspaceNamesIt(inCommit: Bool) async throws {
        let daemon = try TopologyDaemon(extraCapabilities: inCommit ? [DaemonCapabilities.shared.tabWorkspaceName] : [])
        let harness = try await ViewChangePermissionTests.harness(daemon: daemon)
        defer { harness.stop() }
        let moved = try #require(harness.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.last)
        let title = moved.title
        try await ViewChangePermissionTests.run(harness, "palette.moveTabToNewWorkspace", origin: "cli",
                                                target: ActionTargetRef(kind: .tab, id: moved.id))
        try await ViewChangePermissionTests.waitUntil { harness.services.daemon.store.workspaces.count == 2 }
        let created = try #require(harness.services.daemon.store.workspaces.first { $0.key?.rawValue != TopologyDaemon.firstKey })
        try await ViewChangePermissionTests.waitUntil { created.name == title }
        #expect(created.name == title)
        // A daemon with `tab-workspace-name-v1` names it in the move's own
        // commit; an older one gets a rename after the move.
        #expect(daemon.commands.withLock { $0.contains("rename-workspace") } == !inCommit)
    }
}

/// The last tab of a workspace (coordinator decision 2026-10-03): a
/// workspace the user named keeps its name; a default-named one takes the
/// tab's. Before, the new workspace always took the tab's name.
@Suite struct LastTabWorkspaceNameTests {
    private let tab = NewWorkspaceName.Tab(kind: .terminal, title: "vim notes.md")

    @Test func aUserNamedWorkspaceKeepsItsName() {
        #expect(NewWorkspaceName.forLastTab(workspaceName: "Release", workspaceTitle: nil, tab: tab) == "Release")
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-3", workspaceTitle: "Docs", tab: tab) == "Docs")
    }

    @Test func aDefaultNamedWorkspaceTakesTheTabsName() {
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-3", workspaceTitle: nil, tab: tab) == "vim notes.md")
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-12", workspaceTitle: "", tab: tab) == "vim notes.md")
    }

    @Test func onlyTheDaemonsPatternIsADefaultName() {
        #expect(NewWorkspaceName.isDefaultWorkspaceName("workspace-1"))
        #expect(NewWorkspaceName.isDefaultWorkspaceName("workspace-204"))
        #expect(!NewWorkspaceName.isDefaultWorkspaceName("workspace"))
        #expect(!NewWorkspaceName.isDefaultWorkspaceName("workspace-x"))
        #expect(!NewWorkspaceName.isDefaultWorkspaceName("my workspace-2"))
    }
}
