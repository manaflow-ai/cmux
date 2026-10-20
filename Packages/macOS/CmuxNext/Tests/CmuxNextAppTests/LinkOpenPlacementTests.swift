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
        #expect(rule.target(source: "home", takesTabs: false, right: nil) == .splitRight(of: "home"))
    }
}
