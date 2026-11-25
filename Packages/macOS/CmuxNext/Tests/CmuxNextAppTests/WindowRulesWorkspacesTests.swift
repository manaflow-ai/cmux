@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation
import Testing

/// The target, workspace, space and closed history rules answer through the app FFI
/// (cmux-window-rules `targets`, `workspaces`, `closed`, whose own tests hold the cases): these
/// check the round trip, the facts the app sends and the answers it reads back.
@Suite struct WindowRulesWorkspacesTests {
    @Test func nineIsTheLastAndAStepWraps() {
        let rules = WindowRules()
        #expect(rules.ordinal(9, count: 4, pastEnd: .refuse) == 3)
        #expect(rules.ordinal(6, count: 4, pastEnd: .refuse) == nil)
        #expect(rules.ordinal(6, count: 4, pastEnd: .clamp) == 3)
        #expect(rules.step(0, by: -1, count: 3) == 2)
    }

    @Test func anIdWinsOverAFoldedName() {
        let candidates = [WindowRules.Named(id: "a", folded: "work"), WindowRules.Named(id: "work", folded: "home")]
        #expect(WindowRules().named("work", folded: "work", among: candidates) == 1)
        #expect(WindowRules().named("Work", folded: "work", among: candidates) == 0)
    }

    @Test func theExplicitTargetAndTheTabList() {
        let rules = WindowRules()
        let candidates: [WindowRules.TargetRef?] = [WindowRules.TargetRef(kind: "window", id: "w"), nil, WindowRules.TargetRef(kind: "tab", id: "t")]
        #expect(rules.explicitTarget(candidates, kinds: ["tab"]) == 2)
        #expect(rules.tabIDs(" a, ,b ") == ["a", "b"])
        #expect(rules.onePaneRefusal(["p", "q"]) == "tabsInDifferentPanes")
        #expect(rules.refusal(notFound: false, quiet: true) == .quiet)
    }

    @Test func aBulkCloseReadsItsPlanAndAsksForARunningProgram() throws {
        let rules = WindowRules()
        let above = try #require(rules.bulkClose("palette.closeWorkspacesAbove"))
        #expect(above.plan == "aroundSelection" && above.nothingToClose == "noWorkspacesAbove")
        #expect(rules.bulkCloseIDs().count == 8)
        // `window_workspace_survivor` answers `{"window": index}`: a window stays, then every window closes.
        #expect(rules.survivor(active: 0, windows: [["a"], ["b", "c"]], closing: ["a", "b"]) == 1)
        #expect(rules.survivor(active: 1, windows: [["a"], ["b", "c"]], closing: ["a"]) == 1)
        #expect(rules.survivor(active: 0, windows: [["a"], ["b", "c"]], closing: ["a", "b", "c"]) == nil)
        #expect(rules.rowsWindow(["w", nil, "v"]).spans)
        let prompt = try #require(rules.closePrompt(.init(count: 2, programs: ["vim", "top"], askWithoutUndo: false, incognito: false, titled: false)))
        #expect(prompt.title == .count(2) && prompt.body == .running(["top", "vim"]) && prompt.suppressesWarning)
    }

    @Test func eachDestructiveActionRoutesToItsQuestion() {
        #expect(WindowRules().confirmation("space.delete", stash: false) == .spaceDelete)
        #expect(WindowRules().confirmation("workspace.rename", stash: false) == .noQuestion)
    }

    @Test func spaceDefaultsKeepAnAbsoluteDirectoryAndRefuseARelativeOne() throws {
        let rules = WindowRules()
        let patch = try #require(rules.spaceDefaults(cwd: "/Users/me/src", env: nil)).get()
        #expect(patch == WindowRules.DefaultsPatch(cwd: .set("/Users/me/src"), env: nil))
        let refused = rules.spaceDefaults(cwd: "true", env: nil)
        #expect(refused == .failure(.cwdMustBeAbsolute))
        #expect(rules.spaceDelete(warn: true, resolved: true, defaultSpace: false, moves: false, programs: nil) == .readPrograms)
        #expect(rules.spaceClearDefaults(resolved: true, shown: false, inFlight: false, connected: true, held: .notAsked) == .readDaemon)
    }

    /// `~user` names that user's home, as before the rule moved: `~someone/x` is not refused.
    @Test func spaceDefaultsExpandAnotherUsersHome() throws {
        var invocation = ActionInvocation(origin: .cli)
        invocation.arguments["cwd"] = .string(" ~\(NSUserName())/x ")
        let home = try #require(NSHomeDirectoryForUser(NSUserName()))
        #expect(try RoomDefaultsArguments.patch(invocation).cwd == .some(.some(home + "/x")))
        invocation.arguments["cwd"] = .string("~/x")
        #expect(try RoomDefaultsArguments.patch(invocation).cwd == .some(.some(NSHomeDirectory() + "/x")))
    }

    @Test func notesCycleTheStatusAndRefuseAnUnknownOne() throws {
        let update = try #require(WindowRules().notes(.cycleStatus(current: "review"))).get()
        #expect(update.taskStatus == .set("done") && update.capabilities == ["workspace-status-v1"])
        #expect(WindowRules().notes(.setStatus("x")) == .failure(WindowRules.NotesChoices(choices: ["auto", "todo", "working", "needs-attention", "review", "done"])))
    }

    @Test func screensGroupsAndDirectories() {
        let rules = WindowRules()
        #expect(rules.screenClose(.others, index: 0, pinned: [false, true, false]) == [2])
        #expect(rules.screenMove(0, by: -1, count: 2) == nil)
        #expect(rules.screenGroupMove("g", forward: true, screens: [(group: "g", pinned: false), (group: nil, pinned: false)]) == 1)
        #expect(rules.groupChain(from: "a", parents: ["a": "b", "b": nil]) == ["a", "b"])
        #expect(rules.groupFocus(collapsed: true, pinned: false, workspaces: [(id: "w", pending: false)], items: 0)
            == WindowRules.FocusPlan(expands: true, workspace: "w", reopens: false))
        #expect(rules.directory([.init(id: "a", cwd: "/a", terminal: true)], selected: nil, terminalsOnly: true) == "/a")
    }

    @Test func theUndoReducerSettlesAGestureOnceItsItemsAreIn() throws {
        let rules = WindowRules()
        let (state, announced) = try #require(rules.expectClose(.init(), token: 4, tabs: [(id: "a", index: 0)], panes: ["p"], costly: true))
        #expect(announced == .waiting(dropped: []))
        let (after, matched, settled) = try #require(rules.recordClosed(state, items: [.init(id: "i", kind: .tab, pane: "p", tabs: 1)]))
        #expect(matched == [true] && after == WindowRules.UndoState())
        #expect(settled.map(\.token) == [4] && settled.first?.shows == true)
        #expect(rules.undoToast(tabs: 1, shown: 2, allowed: false) == .join(tabs: 3))
    }
}
