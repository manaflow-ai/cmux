@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Lawrence 2026-10-19: "If a user opens a link or a path or whatever from a terminal or ACP or
/// whatever, it needs to open in a new column to the right. Maybe it's not a new column but rather
/// just a split." Every link and path open (terminal Cmd-click, agent chat, Home, Markdown and code
/// pages, `cmux://` path links) asks ``LinkOpenPlacement`` where to go: the pane on the right of
/// the source when there is one, else a new split there. It opened as a tab over the source.
struct LinkOpenPlacementTests {
    private typealias Rule = LinkOpenPlacement<String>

    @Test func withNoPaneOnTheRightALinkOpensInANewSplitThere() {
        let rule = Rule(setting: .splitRight)
        #expect(rule.target(source: "terminal", takesTabs: true, right: nil) == .splitRight(of: "terminal"))
    }

    /// The first open made the right pane; the next one, and any pane already there, gets the tab:
    /// repeated opens never keep splitting.
    @Test func thePaneOnTheRightIsReused() {
        let rule = Rule(setting: .splitRight)
        #expect(rule.target(source: "terminal", takesTabs: true, right: "opened") == .pane("opened"))
        #expect(Rule(setting: .newColumn).target(source: "chat", takesTabs: true, right: "opened") == .pane("opened"))
    }

    @Test func theSourcePaneNeverGetsTheTabByDefault() {
        let rule = Rule(setting: .fallback)
        for right in [nil, "source"] as [String?] {
            #expect(rule.target(source: "source", takesTabs: true, right: right) != .pane("source"))
        }
    }

    @Test func newColumnOpensAColumnWhenNothingIsOnTheRight() {
        #expect(Rule(setting: .newColumn).target(source: "chat", takesTabs: true, right: nil) == .newColumn(rightOf: "chat"))
    }

    @Test func samePaneKeepsTheOldTabInPlace() {
        #expect(Rule(setting: .samePane).target(source: "terminal", takesTabs: true, right: "other") == .pane("terminal"))
    }

    /// The pinned Home column takes no tabs: even Same Pane goes to the right of it.
    @Test func aSourceThatTakesNoTabsAlwaysOpensOnItsRight() {
        let rule = Rule(setting: .samePane)
        #expect(rule.target(source: "home", takesTabs: false, right: "strip") == .pane("strip"))
        #expect(rule.target(source: "home", takesTabs: false, right: nil) == .besideDock("home"))
    }

    /// Lawrence 2026-10-20: "I just clicked a link that you sent me here and it opened in a browser
    /// inside of the current thing ... it needs to not open tabs in here but rather should open it to
    /// the right." A split or column open first makes the tab in the source and then moves it; from
    /// Home's pinned dock the move is refused, so the tab stayed (selected) inside Home. A source that
    /// takes no tabs never gets the tab, whatever the setting: the pane on its right, else the daemon's
    /// column beside the dock.
    @Test(arguments: LinkPlacement.allCases)
    func aSourceThatTakesNoTabsNeverHoldsTheOpenedTab(_ setting: LinkPlacement) {
        let rule = Rule(setting: setting)
        #expect(rule.target(source: "home", takesTabs: false, right: nil) == .besideDock("home"))
        #expect(rule.target(source: "home", takesTabs: false, right: "strip") == .pane("strip"))
    }

    /// Home's dock finds the pane on its right by layout order, so a strip column that is scrolled
    /// or not yet drawn still gets the link: the most recent pane of the first column that takes tabs.
    @Test func thePaneRightOfHomesDockComesFromTheLayout() {
        let columns = [["home"], ["a1", "a2"], ["b"]]
        let takes: (String) -> Bool = { $0 != "home" }
        #expect(Rule.paneRight(of: "home", columns: columns, takesTabs: takes, recency: ["b", "a2", "home"]) == "a2")
        #expect(Rule.paneRight(of: "home", columns: columns, takesTabs: takes, recency: []) == "a1")
    }

    @Test func columnsThatTakeNoTabsAreSkipped() {
        let columns = [["home"], ["other-dock"], ["strip"]]
        #expect(Rule.paneRight(of: "home", columns: columns, takesTabs: { $0 == "strip" }, recency: []) == "strip")
    }

    @Test func aLoneDockHasNoPaneOnItsRight() {
        #expect(Rule.paneRight(of: "home", columns: [["home"]], takesTabs: { $0 != "home" }, recency: []) == nil)
        #expect(Rule.paneRight(of: "home", columns: [["left"], ["home"]], takesTabs: { $0 != "home" }, recency: []) == nil)
    }
}
