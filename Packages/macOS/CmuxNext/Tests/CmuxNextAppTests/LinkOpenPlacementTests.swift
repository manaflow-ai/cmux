@testable import CmuxNextApp
import CmuxNextSettings
import CoreGraphics
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

    /// With the right column not measured, the pane on the right gets the tab.
    @Test func thePaneOnTheRightIsReused() {
        let rule = Rule(setting: .splitRight)
        #expect(rule.target(source: "terminal", takesTabs: true, right: "opened") == .pane("opened"))
        #expect(Rule(setting: .newColumn).target(source: "chat", takesTabs: true, right: "opened") == .pane("opened"))
    }

    /// Leo 2026-10-30: "anything we expect to open on "the right"... if there's already a thing on
    /// the right, there should be logic for just putting it on the lower pane of the right. that
    /// kinda split." With the right column measured (``LinkOpener`` does for a source that takes
    /// tabs), the first open beside a pane already there splits below it; once the column has its
    /// lower pane, opens are tabs there; closing that pane collapses it and the next splits again.
    @Test(arguments: [LinkPlacement.splitRight, .newColumn])
    func somethingAlreadyOnTheRightGetsALowerSplit(_ setting: LinkPlacement) {
        let rule = Rule(setting: setting)
        let wide: (String) -> CGFloat? = { _ in 700 }
        #expect(rule.target(source: "chat", takesTabs: true, right: "diff", column: ["diff"], sourceWidth: 1400, width: wide)
                == .splitBelow(of: "diff"))
        #expect(rule.target(source: "chat", takesTabs: true, right: "diff", column: ["diff", "lower"], sourceWidth: 1400, width: wide)
                == .pane("lower"), "a full column takes a tab in its lower pane, never a third split")
        // The lower pane's last tab closed: the column is one pane again, so the next open splits below it.
        #expect(rule.target(source: "chat", takesTabs: true, right: "diff", column: ["diff"], sourceWidth: 1400, width: wide)
                == .splitBelow(of: "diff"))
    }

    @Test func aNarrowRightColumnTakesTheTabInsteadOfSplitting() {
        let rule = Rule(setting: .splitRight)
        #expect(rule.target(source: "chat", takesTabs: true, right: "diff", column: ["diff"], sourceWidth: 1400, width: { _ in 419 })
                == .pane("diff"))
        #expect(rule.target(source: "chat", takesTabs: true, right: "diff", column: ["diff"], sourceWidth: 479, width: { _ in 700 })
                == .pane("diff"))
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
