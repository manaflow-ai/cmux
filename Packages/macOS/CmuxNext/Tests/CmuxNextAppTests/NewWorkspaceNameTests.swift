import CmuxNextActions
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
    @Test func aTabMovedToANewWorkspaceNamesIt() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let moved = try #require(harness.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.last)
        let title = moved.title
        try await ViewChangePermissionTests.run(harness, "palette.moveTabToNewWorkspace", origin: "cli",
                                                target: ActionTargetRef(kind: .tab, id: moved.id))
        try await ViewChangePermissionTests.waitUntil { harness.services.daemon.store.workspaces.count == 2 }
        let created = try #require(harness.services.daemon.store.workspaces.first { $0.key?.rawValue != TopologyDaemon.firstKey })
        try await ViewChangePermissionTests.waitUntil { created.name == title }
        #expect(created.name == title)
    }
}
