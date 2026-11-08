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

    /// Leo 2026-11-02 23:55Z, on the tab rows: "PLUS THE PLACEMENT LOOKS LIKE SHIT". A row names no machine its
    /// card already names: a Cloud or remote card names its machine in its header, and "This Mac" shows only
    /// when the tab runs somewhere other than this Mac.
    @Test(arguments: [(SidebarMachine.Kind.local, "This Mac"), (.cloud, "Cloud"), (.ssh, "build-box"), (.server, "build-box")])
    func rowsNeverRepeatTheCardsMachine(_ kind: SidebarMachine.Kind, _ word: String) {
        let machine = SidebarMachine(id: kind == .local ? .local : MachineID("box"), name: "build-box", kind: kind)
        let expected = kind == .local ? Strings.hoverCardThisMac : (kind == .cloud ? Strings.hoverCloud : word)
        let chat = SidebarTab(id: TabID("chat"), title: "Agent", kind: .agentChat, folder: "~/src/cmux", state: .working)
        let shell = SidebarTab(id: TabID("shell"), title: "zsh", kind: .terminal, folder: "~/src")
        let page = SidebarTab(id: TabID("page"), title: "Pull request", kind: .browser, host: "github.com")
        for tab in [chat, shell, page] {
            #expect(!line(tab, machine: machine).contains(expected), "\(line(tab, machine: machine))")
        }
    }

    /// The variant that names this Mac on every row still does, for comparison in the gallery.
    @Test func theThisMacVariantNamesThisMac() {
        var style = WorkspaceTabHoverCardStyle.standard
        style.namesLocalMachine = true
        let shell = SidebarTab(id: TabID("shell"), title: "zsh", kind: .terminal, folder: "~/src")
        #expect(line(shell, machine: local, style: style) == "~/src · \(Strings.hoverCardThisMac)")
        let ssh = SidebarMachine(id: MachineID("box"), name: "build-box", kind: .ssh)
        #expect(line(shell, machine: ssh, style: style) == "~/src", "the card's header names build-box")
    }

    /// A tab on a remote workspace names a machine only when it runs somewhere other than the card's header says.
    @Test func aRemoteWorkspacesTabNamesOnlyAnotherMachine() {
        let cloud = SidebarMachine(id: MachineID("box"), name: "cmux-vm-1", kind: .cloud)
        var shell = SidebarTab(id: TabID("remote"), title: "zsh", kind: .remoteTerminal, folder: "~/src")
        shell.machine = "cmux-vm-1"
        #expect(line(shell, machine: cloud) == "~/src", "the header already names this machine")
        shell.machine = "Cloud"
        #expect(line(shell, machine: cloud) == "~/src", "the header already says Cloud")
        shell.machine = "lab-mini"
        #expect(line(shell, machine: cloud) == "~/src · lab-mini")
    }

    @Test func aRemoteTerminalNamesItsOwnSessionOverTheWorkspacesMachine() {
        var remote = SidebarTab(id: TabID("remote"), title: "zsh", kind: .remoteTerminal, folder: "~")
        remote.machine = "lab-mini"
        #expect(line(remote, machine: local) == "~ · lab-mini")
    }

    /// A working chat's spinner sits beside its title, so its line drops "Working".
    @Test func agentRowsShowModelAndTimeAndLeaveWorkingToTheSpinner() {
        var chat = SidebarTab(id: TabID("chat"), title: "claude-sr2-coord", kind: .agentChat, brand: "claude", folder: "~/src/cmux",
                              state: .working, lastActivity: now.addingTimeInterval(-180))
        chat.model = "claude-opus-5-5"
        #expect(line(chat, machine: local) == "~/src/cmux · claude-opus-5-5 · 3m")
        chat.state = .success
        #expect(line(chat, machine: local) == "~/src/cmux · claude-opus-5-5 · \(Strings.activityDone) · 3m")
    }

    /// A session named after its lane path ("gcp-codex-swarm-11/nightly-rollback") shows its short name.
    @Test func aLanePathSessionShowsItsShortName() {
        let chat = SidebarTab(id: TabID("chat"), title: "gcp-codex-swarm-11/nightly-rollback", kind: .agentChat, state: .working)
        #expect(WorkspaceTabHoverCardLine.title(chat) == "nightly-rollback")
        let sentence = SidebarTab(id: TabID("s"), title: "Fix a/b test", kind: .agentChat)
        #expect(WorkspaceTabHoverCardLine.title(sentence) == "Fix a/b test", "a title with words keeps them all")
        let shell = SidebarTab(id: TabID("t"), title: "src/cmux", kind: .terminal)
        #expect(WorkspaceTabHoverCardLine.title(shell) == "src/cmux", "a terminal's path title is its place")
    }

    @Test func terminalRowsShowTheirCommandAndNeverRepeatTheTitle() {
        var shell = SidebarTab(id: TabID("shell"), title: "~", kind: .terminal, folder: "~")
        #expect(line(shell, machine: local).isEmpty, "\"~\" under \"~\" says nothing")
        shell.command = "npm test"
        #expect(line(shell, machine: local) == "npm test")
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
        row.configure(title: "w", tabs: [SidebarTab(id: TabID("n"), title: Strings.hoverCardNewTab, kind: .newTab)], now: now, machine: local)
        #expect(row.reportedLines == [Strings.hoverCardNewTab])
    }

    @Test func pageAddressesGiveAPathAndTheSitesIcon() {
        #expect(SidebarMapping.pagePath("https://github.com/manaflow-ai/cmux/pull/12/?tab=files#diff") == "/manaflow-ai/cmux/pull/12")
        #expect(SidebarMapping.pagePath("https://github.com/") == nil)
        #expect(SidebarMapping.pagePath("about:blank") == nil)
        #expect(SidebarMapping.siteFavicon("https://github.com/manaflow-ai/cmux?x=1") == "https://github.com/favicon.ico")
        #expect(SidebarMapping.siteFavicon("http://localhost:3000/app") == nil, "a loopback page may be another machine's port")
        #expect(SidebarMapping.siteFavicon("http://127.0.0.1:8080/") == nil)
        #expect(SidebarMapping.siteFavicon("http://[::1]:8080/") == nil)
        #expect(SidebarMapping.siteFavicon("about:blank") == nil)
        #expect(SidebarMapping.siteFavicon("file:///tmp/a.html") == nil)
        #expect(SidebarMapping.favicon("https://cdn.example/icon.png", page: "https://github.com/a") == "https://cdn.example/icon.png")
        #expect(SidebarMapping.favicon(nil, page: "https://github.com/a") == "https://github.com/favicon.ico")
    }
}
