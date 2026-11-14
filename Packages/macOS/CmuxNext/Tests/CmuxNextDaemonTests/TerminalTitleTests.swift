import Foundation
import Observation
import os
import Testing
@testable import CmuxNextDaemon

/// A terminal's title as tabs show it (plans/cmux-next/osc-titles.md): the text and activity the daemon split from the
/// program's OSC 0/2 title (main-thread-scheduling.md D2; the glyph rule and its cases are in cmux-tui-core's
/// `terminal_title.rs`), a user's or the CLI's name above it, and an unchanged split that redraws nothing.
@MainActor
struct TerminalTitleTests {
    /// The daemon's `title-changed` line: `text` and `activity` win; a daemon from before them sends the raw title,
    /// shown as is (the app has no glyph rule).
    @Test func aTitleChangedLineCarriesTheDaemonsSplit() throws {
        func decode(_ json: String) -> DaemonEvent { DaemonEvent.decode(name: "title-changed", line: Data(json.utf8)) }
        guard case .titleChanged(1, let text, let activity) =
            decode(#"{"event":"title-changed","surface":1,"title":"⠐ Fix the login bug","text":"Fix the login bug","activity":"working"}"#)
        else { Issue.record("not a title change"); return }
        #expect(text == "Fix the login bug")
        #expect(activity == .working)
        guard case .titleChanged(1, let old, let none) = decode(#"{"event":"title-changed","surface":1,"title":"⠐ Fix the login bug"}"#)
        else { Issue.record("not a title change"); return }
        #expect(old == "⠐ Fix the login bug")
        #expect(none == nil)
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
        store.apply(.titleChanged(surface: 1, title: "Fix the login bug", activity: .working))
        let tab = try #require(store.tab(surface: 1))
        #expect(tab.displayTitle == "Fix the login bug")
        #expect(tab.titleActivity == .working)

        // One-shot tracking: the count is the redraws a view reading the shown title would get.
        let redraws = OSAllocatedUnfairLock(initialState: 0)
        func count() -> Int { redraws.withLock { $0 } }
        withObservationTracking { _ = tab.displayTitle } onChange: { redraws.withLock { $0 += 1 } }
        store.apply(.titleChanged(surface: 1, title: "Fix the login bug", activity: .working))
        #expect(count() == 0)
        #expect(tab.displayTitle == "Fix the login bug")

        store.apply(.titleChanged(surface: 1, title: "Fix the login bug", activity: .idle))
        #expect(count() == 0)
        #expect(tab.titleActivity == .idle)

        store.apply(.titleChanged(surface: 1, title: "Run the tests", activity: .working))
        #expect(count() == 1)
        #expect(tab.displayTitle == "Run the tests")
    }

    @Test func aNameAlwaysWinsAndClearingItShowsTheLiveTitle() throws {
        let store = store(title: "zsh")
        let tab = try #require(store.tab(surface: 1))
        tab.setName("Release")
        store.apply(.titleChanged(surface: 1, title: "Fix the login bug", activity: .working))
        #expect(tab.displayTitle == "Release")
        tab.setName(nil)
        #expect(tab.displayTitle == "Fix the login bug")
        tab.setName("")
        #expect(tab.displayTitle == "Fix the login bug")
    }

    /// A tree tab carries the daemon's split (`title_text`, `title_activity`); an older daemon's raw `title` is the text.
    @Test func aSnapshotCarriesTheDaemonsSplit() throws {
        func tab(_ json: String) throws -> TabSnapshot { try WireCoding.decoder().decode(TabSnapshot.self, from: Data(json.utf8)) }
        let split = try tab(#"{"surface":1,"kind":"pty","title":"⠐ Deploy staging","title_text":"Deploy staging","title_activity":"working"}"#)
        #expect(split.title == "Deploy staging")
        #expect(split.titleActivity == .working)
        let old = try tab(#"{"surface":1,"kind":"pty","title":"⠐ Deploy staging"}"#)
        #expect(old.title == "⠐ Deploy staging")
        #expect(old.titleActivity == nil)
    }

    @Test func aSnapshotTitleReachesTheTab() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Deploy staging", titleActivity: .working)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        let tab = try #require(store.tab(surface: 1))
        #expect(tab.titleText == "Deploy staging")
        #expect(tab.titleActivity == .working)
    }
}
