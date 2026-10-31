@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import Testing

/// The tab strip shows a terminal's title by its words and its spinner glyph as the busy mark
/// (plans/cmux-next/osc-titles.md); a user's name wins over both.
@MainActor
struct TerminalTitleTabItemTests {
    private func store(title: String, name: String? = nil) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, name: name, title: title)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        return store
    }

    @Test func aSpinnerTitleShowsItsWordsAndTheBusyMark() throws {
        let tab = try #require(store(title: "⠐ Fix the login bug").tab(surface: 1))
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.title == "Fix the login bug")
        #expect(item.isBusy)
    }

    @Test func aRestingAgentTitleIsNotBusy() throws {
        let tab = try #require(store(title: "✳ Claude Code").tab(surface: 1))
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.title == "Claude Code")
        #expect(!item.isBusy)
    }

    @Test func aRenamedTabKeepsItsName() throws {
        let tab = try #require(store(title: "⠐ Fix the login bug", name: "Release").tab(surface: 1))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").title == "Release")
    }

    @Test(arguments: ["~", "zsh", "bash"])
    func aUserNameThatLooksLikeAShellTitleKeepsItsName(name: String) throws {
        let tab = try #require(store(title: "zsh", name: name).tab(surface: 1))
        tab.setObservedCwd("/tmp/cmux-demo")
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").title == name)
    }

    @Test func aBareShellTitleUsesTheReportedFolder() throws {
        let tab = try #require(store(title: "~").tab(surface: 1))
        tab.setObservedCwd("/tmp/cmux-demo")
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.title == "/tmp/cmux-demo")
        #expect(item.subtitle == "/tmp/cmux-demo")
    }

    @Test func aDefaultShellTitleUsesTheReportedFolder() throws {
        let tab = try #require(store(title: "zsh").tab(surface: 1))
        tab.setObservedCwd("/tmp/cmux-demo")
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").title == "/tmp/cmux-demo")
    }
}
