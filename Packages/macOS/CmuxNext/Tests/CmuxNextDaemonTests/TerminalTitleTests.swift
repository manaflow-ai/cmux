import Observation
import os
import Testing
@testable import CmuxNextDaemon

/// A terminal's title as tabs show it (plans/cmux-next/osc-titles.md): the
/// program's OSC 0/2 text without its leading status glyphs, a user's or the
/// CLI's name above it, and a spinner frame that redraws nothing.
@MainActor
struct TerminalTitleTests {
    @Test(arguments: [
        ("⠐ Fix the login bug", "Fix the login bug", TerminalTitle.Activity?.some(.working)),
        ("⠂ Fix the login bug", "Fix the login bug", .working),
        ("✳ Claude Code", "Claude Code", .idle),
        ("● build", "build", .idle),
        ("✔︎ tests passed", "tests passed", .done),
        ("✘ deploy", "deploy", .failed),
        ("✳ ⠂ Task", "Task", .working),
        ("vim notes.md", "vim notes.md", nil),
        ("~/src · main", "~/src · main", nil),
        ("⠂", "⠂", .working),
    ])
    func leadingStatusGlyphsBecomeTheActivity(raw: String, text: String, activity: TerminalTitle.Activity?) {
        let title = TerminalTitle(raw: raw)
        #expect(title.text == text)
        #expect(title.activity == activity)
    }

    private func store(kind: TabKind = .pty, title: String = "") -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: kind, title: title)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        return store
    }

    @Test func aSpinnerFrameChangesNoShownTitle() throws {
        let store = store()
        store.apply(.titleChanged(surface: 1, title: "⠂ Fix the login bug"))
        let tab = try #require(store.tab(surface: 1))
        #expect(tab.displayTitle == "Fix the login bug")
        #expect(tab.titleActivity == .working)

        // One-shot tracking: the count is the redraws a view reading the shown title would get.
        let redraws = OSAllocatedUnfairLock(initialState: 0)
        func count() -> Int { redraws.withLock { $0 } }
        withObservationTracking { _ = tab.displayTitle } onChange: { redraws.withLock { $0 += 1 } }
        store.apply(.titleChanged(surface: 1, title: "⠐ Fix the login bug"))
        #expect(count() == 0)
        #expect(tab.displayTitle == "Fix the login bug")

        store.apply(.titleChanged(surface: 1, title: "✳ Fix the login bug"))
        #expect(count() == 0)
        #expect(tab.titleActivity == .idle)

        store.apply(.titleChanged(surface: 1, title: "⠂ Run the tests"))
        #expect(count() == 1)
        #expect(tab.displayTitle == "Run the tests")
    }

    @Test func aNameAlwaysWinsAndClearingItShowsTheLiveTitle() throws {
        let store = store(title: "zsh")
        let tab = try #require(store.tab(surface: 1))
        tab.setName("Release")
        store.apply(.titleChanged(surface: 1, title: "⠂ Fix the login bug"))
        #expect(tab.displayTitle == "Release")
        tab.setName(nil)
        #expect(tab.displayTitle == "Fix the login bug")
        tab.setName("")
        #expect(tab.displayTitle == "Fix the login bug")
    }

    @Test func aSnapshotTitleIsSplitToo() throws {
        let tab = try #require(store(title: "⠐ Deploy staging").tab(surface: 1))
        #expect(tab.titleText == "Deploy staging")
        #expect(tab.titleActivity == .working)
    }

    @Test func aPageTitleKeepsItsGlyphs() throws {
        let tab = try #require(store(kind: .browser, title: "● Slack | general").tab(surface: 1))
        #expect(tab.displayTitle == "● Slack | general")
        #expect(tab.titleActivity == nil)
    }
}
