import CmuxNextWindowRules
import Testing

/// The smaller handlers' rules answer through the app FFI (cmux-window-rules `notifications`, `history`, `remote`,
/// `browser`, `files`, `appearance`, whose own tests hold the cases): these check the round trip, the facts the app
/// sends and the answers it reads back.
@Suite struct WindowRulesMiscTests {
    private let rules = WindowRules()

    @Test func markOldestReadsItAndOpensTheNext() throws {
        let plan = try #require(rules.unreadPlan(.markOldestAndJumpNext, createdAt: [9, nil, 4]), "the FFI did not answer")
        #expect(plan.acknowledge == [1] && plan.open == 2 && plan.refusal == nil)
        #expect(rules.unreadPlan(.markAllRead, createdAt: [])?.refusal == "noUnread")
        #expect(rules.lastPrompt([3, 7, 5]) == 1)
        #expect(rules.lastPrompt([]) == nil)
        #expect(rules.toggleMute(["b"], key: "a", legacy: nil) == ["a", "b"])
        #expect(rules.toggleBanners("never") == "unlessFocused")
    }

    /// Jump to Last Prompt sends the prompted tabs in tree order, so a tie goes to the first in the tree,
    /// not to the lowest surface id.
    @Test func lastPromptTieGoesToTheFirstInTheTree() {
        let tree: [(surface: Int, prompt: UInt64?)] = [(9, nil), (7, 5), (3, 8), (1, 8)]
        #expect(rules.lastPrompted(tree, prompt: { $0.prompt })?.surface == 3)
        #expect(rules.lastPrompted(tree.filter { $0.prompt == nil }, prompt: { $0.prompt }) == nil)
    }

    @Test func historyTableAndLayoutUndo() throws {
        let table = try #require(rules.historyActions())
        #expect(table.walks.map(\.action) == ["focusHistoryBack", "focusHistoryForward", "focusHistoryLast"])
        #expect(table.historyPage == ["history.show", "browserShowHistory"])
        let undo = rules.undoReply(confirmationRequired: true, revision: 8, closesPanes: nil)
        #expect(undo?.pending == 8 && undo?.closesPanes == 1)
    }

    @Test func remoteMachineAndTerminalHere() {
        let machines = [WindowRules.Machine(id: "m1", names: ["Box"]), WindowRules.Machine(id: "m2", names: ["dev"])]
        guard case .success(0)? = rules.machine(target: "BOX", machines: machines, active: nil) else {
            Issue.record("BOX is m1")
            return
        }
        guard case .failure(.noMachine)? = rules.machine(target: nil, machines: machines, active: nil) else {
            Issue.record("two machines and no target name none")
            return
        }
        #expect(rules.terminalHere(direction: "below", sameMachine: true, cwd: false) == .open(split: "down"))
        #expect(rules.terminalHere(direction: nil, sameMachine: true, cwd: false) == .newSurface)
    }

    @Test func browserFitDeviceAndPictureInPicture() {
        let fit = rules.fit(fixed: "1280", asked: nil, current: "1280")
        #expect(fit?.fit == nil && fit?.capability == "browserFit")
        #expect(rules.fitActions()?.map(\.action) == ["browserFitDesktop", "browserFitDesktop1280", "browserFit"])
        #expect(rules.menuFits(fit: true, fitWidth: false) == ["16:9"])
        let cleared = rules.device("none", orientation: nil)
        #expect(cleared != nil && cleared?.device == nil)
        #expect(rules.device(nil, orientation: nil) == nil)
        let facts = WindowRules.PipFacts(named: false, namedPage: false, card: true, shownVideo: true, focused: false, focusedVideo: false)
        #expect(rules.pipPage(facts) == .shown)
        #expect(rules.pipRow(.init(enabled: true, target: "tab", video: true, floating: true))?.exit == true)
    }

    @Test func filesOpenRules() {
        #expect(rules.openMarkdown(path: "a.md", local: false, showsChat: false, allowsViewChange: true)?.refusal == "pathNotAbsolute")
        let diff = rules.openDiff(.init(patch: false, path: nil, paneFolder: "/r", allowsViewChange: true, besideCaller: true))
        #expect(diff?.decision == "folder" && diff?.folder == "/r" && diff?.focus == false)
        #expect(rules.diffFailed(local: true, allowsViewChange: false) == "pickerNeedsFocus")
        let bindings = rules.editorBindings([.init(action: "findNext", runsEditorCommand: false), .init(action: "editorRun", runsEditorCommand: true)])
        #expect(bindings?.map(\.action) == ["editorRun"])
        #expect(rules.vscodeOpen(.init(local: true, installed: true, byPerson: false, terminal: true, cwd: "/w"))?.folder == "/w")
        #expect(rules.openWith(app: nil, byPerson: false, selection: true)?.decision == "noSuchApp")
    }

    @Test func appearanceRingStyleAndKeymapToast() {
        let verb = rules.appearance(.init(scope: "workspace", property: "theme", set: true))
        #expect(verb?.themeAction == "workspace.setTheme" && verb?.properties == [])
        #expect(rules.appearance(.init(scope: "app", property: nil, set: false))?.refusal == "badProperty")
        // pane.clearBackground: every property set at the pane level (not blur), no theme action.
        let clear = rules.appearance(.init(scope: "pane", property: nil, set: false))
        #expect(clear?.level == "pane" && clear?.themeAction == nil)
        #expect(clear?.properties == ["theme", "background", "tint", "opacity", "fontSize", "cursorStyle"])
        let edits = rules.focusRingStyle("glow", wasEnabled: false)
        #expect(edits?.map(\.path) == [["focusRing", "style"], ["focusRing", "enabled"]])
        #expect(edits?.first?.text == "glow" && edits?.last?.flag == true)
        #expect(rules.keymapToast(preset: "iterm2", changed: ["selectSurfaceByNumber"])?.lines == ["title", "iTerm2Numbers"])
    }
}
