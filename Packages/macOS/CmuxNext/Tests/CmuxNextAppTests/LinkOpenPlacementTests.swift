import CmuxNextAgentPane
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

    /// Main pane layout: the strip column right of the docked chat is the chat's right side, so the
    /// same lower split applies there (ux-owner 2026-10-30, on Leo's "anything we expect to open on
    /// 'the right'"); unmeasured, the strip pane still gets the tab.
    @Test func theMainPaneStripColumnGetsTheSameLowerSplit() {
        let wide: (String) -> CGFloat? = { _ in 700 }
        #expect(Rule.inColumn(right: "strip", column: ["strip"], sourceWidth: 1400, width: wide) == .splitBelow(of: "strip"))
        #expect(Rule.inColumn(right: "strip", column: ["strip", "lower"], sourceWidth: 1400, width: wide) == .pane("lower"))
        #expect(Rule.inColumn(right: "strip", column: [], sourceWidth: 1400, width: wide) == .pane("strip"))
    }

    /// Leo 2026-10-31: "imo in this case, just open it on the existing. you only need the rightmost
    /// botom auto split when there's a terminal that gets opened when there's already a browser, and
    /// vice versa". A link beside a chat whose right pane already holds a browser is a tab there; a
    /// folder's terminal splits below it. The docked chat's strip column follows the same rule.
    @Test func aLinkGoesToTheBrowserPaneAlreadyOnTheRight() {
        let wide: (String) -> CGFloat? = { _ in 700 }
        let holds: (String, RightColumnPlacement.Kind) -> Bool = { pane, kind in (pane == "web" && kind == .browser) || (pane == "shell" && kind == .terminal) }
        let rule = Rule(setting: .splitRight)
        #expect(rule.target(source: "chat", takesTabs: true, right: "web", column: ["web"], sourceWidth: 1400, width: wide,
                            kind: .browser, holds: holds) == .pane("web"))
        #expect(rule.target(source: "chat", takesTabs: true, right: "web", column: ["web"], sourceWidth: 1400, width: wide,
                            kind: .terminal, holds: holds) == .splitBelow(of: "web"))
        #expect(rule.target(source: "chat", takesTabs: true, right: "web", column: ["web", "shell"], sourceWidth: 1400, width: wide,
                            kind: .browser, holds: holds) == .pane("web"), "the browser pane, not the lower one")
        #expect(Rule.inColumn(right: "web", column: ["web"], sourceWidth: 1400, width: wide, kind: .browser, holds: holds) == .pane("web"))
        #expect(Rule.inColumn(right: "shell", column: ["shell"], sourceWidth: 1400, width: wide, kind: .browser, holds: holds)
                == .splitBelow(of: "shell"))
    }

    /// Review of #28044 at 34122a1a: with nothing on its right, a 900-959 pt source still split to
    /// under the 480 pt chat floor. Measured narrow, it keeps the tab; a new column needs no floor.
    @Test func aNarrowSourceWithNothingOnItsRightKeepsTheTab() {
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: nil, sourceWidth: 959) == .pane("chat"))
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: nil, sourceWidth: 960) == .splitRight(of: "chat"))
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: nil) == .splitRight(of: "chat"), "unmeasured: no floor")
        #expect(Rule(setting: .newColumn).target(source: "chat", takesTabs: true, right: nil, sourceWidth: 600) == .newColumn(rightOf: "chat"))
        #expect(Rule(setting: .splitRight).target(source: "home", takesTabs: false, right: nil, sourceWidth: 600) == .besideDock("home"))
    }

    /// Review of #28044 at bd2b918d: link A opens on the right (upper pane), B splits below it (lower
    /// pane), and A again targets the lower pane, which holds no A. The panes searched for a tab of
    /// that page are the whole right column, so A is selected where it is, never opened twice.
    @Test func aLinkOpenAgainIsFoundAnywhereInTheRightColumn() {
        let rule = Rule(setting: .splitRight), wide: (String) -> CGFloat? = { _ in 700 }
        var shows: [String: Set<String>] = ["chat": []]
        var column: [String] = []
        func open(_ url: String) -> String {
            let target = rule.target(source: "chat", takesTabs: true, right: column.first, column: column, sourceWidth: 1400, width: wide)
            if let pane = Rule.reusePanes(target: target, column: column, source: "chat").first(where: { shows[$0]?.contains(url) == true }) {
                return "selected in \(pane)"
            }
            switch target {
            case .splitRight: column = ["upper"]; shows["upper", default: []].insert(url); return "opened in upper"
            case .splitBelow: column.append("lower"); shows["lower", default: []].insert(url); return "opened in lower"
            case .pane(let pane): shows[pane, default: []].insert(url); return "opened in \(pane)"
            default: return "unexpected \(target)"
            }
        }
        #expect(open("A") == "opened in upper")
        #expect(open("B") == "opened in lower")
        #expect(rule.target(source: "chat", takesTabs: true, right: "upper", column: column, sourceWidth: 1400, width: wide) == .pane("lower"),
                "fixture: a third open targets the lower pane")
        #expect(open("A") == "selected in upper", "A was opened a second time in the lower pane")
        #expect(Rule.reusePanes(target: .pane("lower"), column: ["upper", "lower"], source: "chat") == ["lower", "upper"])
        #expect(Rule.reusePanes(target: .splitRight(of: "chat"), column: [], source: "chat").isEmpty)
        // Review of #28044 at c15e0d89: Same Pane opens in the source, so nothing on the right is reused.
        #expect(Rule.reusePanes(target: .pane("chat"), column: ["upper", "lower"], source: "chat").isEmpty)
        let samePane = Rule(setting: .samePane).target(source: "chat", takesTabs: true, right: "upper", column: ["upper", "lower"],
                                                       sourceWidth: 1400, width: wide)
        #expect(Rule.reusePanes(target: samePane, column: ["upper", "lower"], source: "chat").isEmpty,
                "a Same Pane link selected its page's tab on the right instead of opening in the source")
    }

    /// A pane with no width yet (not laid out, no window) is unmeasured, not narrow: its link still
    /// opens in a split on its right (fleet run of #28044 at 8e520360, SideOpenStripTests).
    @Test func anUnmeasuredSourceIsNotTakenForANarrowOne() {
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: nil, sourceWidth: nil) == .splitRight(of: "chat"))
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
