@testable import CmuxNextBridge
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-01, on the workspace hover preview's tab rows: "local or nonlocal is probably useful to see in
/// the hover previews" and "these are not informative enough nor look very good. there's no symbols, not much
/// metadata, nothing". Each agent chat and terminal row names where it runs; pages show their path, never
/// the title twice; a row with no fact has no bare kind word under it.
@MainActor struct WorkspaceTabHoverCardRichRowsTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let local = SidebarMachine(id: .local, name: "studio", kind: .local)

    private func line(_ tab: SidebarTab, machine: SidebarMachine?, style: WorkspaceTabHoverCardStyle = .standard) -> String {
        WorkspaceTabHoverCardLine(tab, style: style, now: now, machine: machine).detail
    }

    @Test(arguments: [(SidebarMachine.Kind.local, "This Mac"), (.cloud, "Cloud"), (.ssh, "build-box"), (.server, "build-box")])
    func agentAndTerminalRowsNameTheirMachine(_ kind: SidebarMachine.Kind, _ word: String) {
        let machine = SidebarMachine(id: kind == .local ? .local : MachineID("box"), name: "build-box", kind: kind)
        let expected = kind == .local ? Strings.hoverCardThisMac : (kind == .cloud ? Strings.hoverCloud : word)
        let chat = SidebarTab(id: TabID("chat"), title: "Agent", kind: .agentChat, folder: "~/src/cmux", state: .working)
        let shell = SidebarTab(id: TabID("shell"), title: "zsh", kind: .terminal, folder: "~/src")
        let page = SidebarTab(id: TabID("page"), title: "Pull request", kind: .browser, host: "github.com")
        #expect(line(chat, machine: machine).contains(expected), "\(line(chat, machine: machine))")
        #expect(line(shell, machine: machine).contains(expected), "\(line(shell, machine: machine))")
        #expect(!line(page, machine: machine).contains(expected), "a page runs in this app: \(line(page, machine: machine))")
    }

    @Test func aRemoteTerminalNamesItsOwnSessionOverTheWorkspacesMachine() {
        var remote = SidebarTab(id: TabID("remote"), title: "zsh", kind: .remoteTerminal, folder: "~")
        remote.machine = "lab-mini"
        #expect(line(remote, machine: local) == "~ · lab-mini")
    }

    @Test func theRemoteOnlyVariantLeavesThisMacUnnamed() {
        var style = WorkspaceTabHoverCardStyle.standard
        style.namesLocalMachine = false
        let shell = SidebarTab(id: TabID("shell"), title: "zsh", kind: .terminal, folder: "~/src")
        #expect(line(shell, machine: local, style: style) == "~/src")
        let ssh = SidebarMachine(id: MachineID("box"), name: "build-box", kind: .ssh)
        #expect(line(shell, machine: ssh, style: style) == "~/src · build-box")
    }

    @Test func agentRowsShowModelStateMachineAndTime() {
        var chat = SidebarTab(id: TabID("chat"), title: "claude-sr2-coord", kind: .agentChat, brand: "claude", folder: "~/src/cmux",
                              state: .working, lastActivity: now.addingTimeInterval(-180))
        chat.model = "claude-opus-5-5"
        #expect(line(chat, machine: local) == "~/src/cmux · claude-opus-5-5 · \(Strings.priorityWorking) · \(Strings.hoverCardThisMac) · 3m")
    }

    @Test func terminalRowsShowTheirCommandAndNeverRepeatTheTitle() {
        var shell = SidebarTab(id: TabID("shell"), title: "~", kind: .terminal, folder: "~")
        #expect(line(shell, machine: local) == Strings.hoverCardThisMac, "\"~\" under \"~\" says nothing")
        shell.command = "npm test"
        #expect(line(shell, machine: local) == "npm test · \(Strings.hoverCardThisMac)")
    }

    @Test func pagesShowTheirPathAndNeverRepeatTheTitle() {
        var unloaded = SidebarTab(id: TabID("a"), title: "github.com", kind: .browser, host: "github.com")
        #expect(line(unloaded, machine: local).isEmpty, "\"github.com\" under \"github.com\" says nothing")
        unloaded.path = "/manaflow-ai/cmux/pull/12"
        #expect(line(unloaded, machine: local) == "/manaflow-ai/cmux/pull/12")
        var titled = SidebarTab(id: TabID("b"), title: "Fix the hover card · Pull Request #12", kind: .browser, host: "github.com")
        titled.path = "/manaflow-ai/cmux/pull/12"
        #expect(line(titled, machine: local) == "github.com/manaflow-ai/cmux/pull/12")
    }

    @Test func aNewTabHasNoKindWordUnderIt() {
        let row = WorkspaceTabHoverCardView()
        row.configure(title: "w", tabs: [SidebarTab(id: TabID("n"), title: "New Tab", kind: .newTab)], now: now, machine: local)
        #expect(row.reportedLines == ["New Tab"])
    }

    @Test func pageAddressesGiveAPathAndTheSitesIcon() {
        #expect(SidebarMapping.pagePath("https://github.com/manaflow-ai/cmux/pull/12/?tab=files#diff") == "/manaflow-ai/cmux/pull/12")
        #expect(SidebarMapping.pagePath("https://github.com/") == nil)
        #expect(SidebarMapping.pagePath("about:blank") == nil)
        #expect(SidebarMapping.siteFavicon("https://github.com/manaflow-ai/cmux?x=1") == "https://github.com/favicon.ico")
        #expect(SidebarMapping.siteFavicon("http://localhost:3000/app") == "http://localhost:3000/favicon.ico")
        #expect(SidebarMapping.siteFavicon("about:blank") == nil)
        #expect(SidebarMapping.siteFavicon("file:///tmp/a.html") == nil)
        #expect(SidebarMapping.favicon("https://cdn.example/icon.png", page: "https://github.com/a") == "https://cdn.example/icon.png")
        #expect(SidebarMapping.favicon(nil, page: "https://github.com/a") == "https://github.com/favicon.ico")
    }
}
