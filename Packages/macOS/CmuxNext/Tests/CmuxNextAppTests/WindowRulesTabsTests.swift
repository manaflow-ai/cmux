@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation
import Testing

/// The tab and pane rules answer through the app FFI (cmux-window-rules `tabs`, whose own tests hold the cases):
/// these check the round trip, the facts the app sends and the answers it reads back.
@MainActor @Suite struct WindowRulesTabsTests {
    @Test func aPersonsCmdTOpensThePageAndTheMenuNamesTheSelectedKind() throws {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .browser, title: "t", url: "https://a.test"))
        var facts = NewTabKind.facts(tab, id: tab.id, agent: false, newTabPage: false)
        facts.user = true
        facts.followsSetting = true
        facts.canHostAgent = true
        let answer = try #require(WindowRules().newTabKind(facts), "the FFI did not answer")
        #expect(answer.kind == .page)
        #expect(answer.sameKind == .browser(engine: tab.browserEngine))
        facts.canHostAgent = false
        #expect(WindowRules().newTabKind(facts)?.kind == .terminal)
    }

    @Test func browserOpenRefusesWordsAndOpensAURL() {
        guard case .refuse = BrowserOpenPlan.make(url: "two words", engine: nil, origin: .user) else {
            Issue.record("words opened")
            return
        }
        #expect(BrowserOpenPlan.make(url: "https://a.test/x", engine: "webkit", origin: .user)
            == .open(BrowserOpenPlan(url: URL(string: "https://a.test/x"), engine: "webkit")))
        #expect(BrowserOpenPlan.make(url: nil, engine: nil, origin: .cli) == .open(BrowserOpenPlan(url: nil, engine: nil)))
    }

    @Test func aLeftSplitIsARightSplitSwappedBack() throws {
        let folders = WindowRules.SplitFolders(explicit: nil, uninherited: nil, inherited: "/w", selected: "/s", first: nil)
        let plan = try #require(WindowRules().split(WindowRules.SplitFacts(direction: "left", folders: folders, tool: "split", page: false, shown: true)))
        #expect(plan.action == "split")
        #expect(plan.edge == "left")
        #expect(plan.daemonDirection == "right")
        #expect(plan.swapTowards == "right")
        #expect(plan.splitAction == "splitLeft")
        #expect(plan.cwd == "/w")
    }

    @Test func numbersMovesAndTables() {
        let rules = WindowRules()
        #expect(rules.tabByNumber(9, count: 4) == 3)
        #expect(rules.paneByNumber(5, count: 4) == nil)
        #expect(rules.moveToSplit(WindowRules.MoveToSplitFacts(direction: "up", group: true, chatDock: true))?.decision == "refuse")
        // The dock splits only into a column after it: a lone docked chat, another edge, a tab that is not a chat refuse.
        #expect(rules.moveToSplit(WindowRules.MoveToSplitFacts(direction: nil, group: false, tabsInPane: 2, chatDock: true, chat: true, dockColumn: true))?.decision == "columnAfterDock")
        #expect(rules.moveToSplit(WindowRules.MoveToSplitFacts(direction: nil, group: false, tabsInPane: 1, chatDock: true, chat: true, dockColumn: true))?.decision == "refuse")
        #expect(rules.moveToSplit(WindowRules.MoveToSplitFacts(direction: "down", group: false, tabsInPane: 2, chatDock: true, chat: true, dockColumn: true))?.decision == "refuse")
        #expect(rules.moveToSplit(WindowRules.MoveToSplitFacts(direction: nil, group: false, tabsInPane: 2, chatDock: true, chat: false, dockColumn: true))?.decision == "refuse")
        #expect(rules.groupCollapse(nil, current: false) == true)
        #expect(rules.restartRefusal(pty: true, dead: false, failed: false).refusal == "tabNotDead")
        #expect(rules.iconUndo(user: true, previous: nil, icon: "star") == "set")
        #expect(rules.duplicate([WindowRules.DuplicateFacts(browser: false, localBrowser: false, agent: false, localPage: true, page: false)]) == nil)
        #expect(rules.terminalBindings().count == 9)
        #expect(rules.clearFailureKind("/Users/x said no") == "other")
        #expect(rules.shellQuoted("it's") == "'it'\\''s'")
        #expect(rules.workspaceIDText(["ws_1"], refs: true) == "workspace_ref=workspace:ws_1\nworkspace_id=ws_1")
        #expect(rules.autoDirection(width: 10, height: 20, roomRight: true, roomDown: false)?.fitting == "right")
        #expect(rules.tabBar(appPane: true, pinnedDock: false, pinnedDockHidesTabBar: false)?.toggle == "appPaneHasNoTabBar")
    }
}
