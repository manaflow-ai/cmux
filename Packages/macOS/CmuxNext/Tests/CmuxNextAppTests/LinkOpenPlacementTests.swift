import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
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

    /// Leo 2026-11-07: "if you click open on GitHub, it's already in the second pane, and it
    /// therefore doesn't need to open the right split. It can just open the tab in its existing
    /// pane." A page that already sits beside another pane (`left`) and has nothing on its own right
    /// opens a tab in its own pane; it split again, so the screen gained a third column.
    @Test func aPageAlreadyBesideAnotherPaneOpensATabInItsOwnPane() {
        let rule = Rule(setting: .splitRight)
        #expect(rule.target(source: "github", takesTabs: true, right: nil, left: "chat") == .pane("github"))
        // A pane already on its right still gets the open, as before.
        #expect(rule.target(source: "github", takesTabs: true, right: "browser", left: "chat") == .pane("browser"))
        // Nothing on its left: the first open beside it still splits right.
        #expect(rule.target(source: "github", takesTabs: true, right: nil, left: nil) == .splitRight(of: "github"))
        // A pane that takes no tabs still opens beside itself, and a chosen new column stays a column.
        #expect(rule.target(source: "dock", takesTabs: false, right: nil, left: "chat") == .besideDock("dock"))
        #expect(Rule(setting: .newColumn).target(source: "github", takesTabs: true, right: nil, left: "chat")
                == .newColumn(rightOf: "github"))
    }

    /// Review of #37573 at bf2ce583: the GitHub page, a file, a diff and What's New are conversation
    /// tabs with a page source, so they count as pages; an agent chat and a terminal do not.
    @Test func internalPagesAndBrowserTabsArePagesButChatsAndTerminalsAreNot() {
        func tab(_ kind: TabKind, _ conversation: ConversationTabRef? = nil) -> TabModel {
            var snapshot = TabSnapshot(surface: 1, kind: kind, cwd: nil)
            snapshot.conversation = conversation
            return TabModel(snapshot)
        }
        #expect(tab(.conversation, ConversationTabRef(page: "github", route: "https://github.com/o/r/pull/1")).showsPage)
        #expect(tab(.conversation, ConversationTabRef(page: "files", route: "/tmp/a.swift")).showsPage)
        #expect(tab(.browser).showsPage)
        #expect(!tab(.conversation, ConversationTabRef(agentSession: AgentSessionRef(host: "h", session: "s", harness: "claude"))).showsPage)
        #expect(!tab(.pty).showsPage)
        #expect(!tab(.remoteTerminal).showsPage)
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

    // MARK: The nearest browser on the right (Leo 2026-11-11)

    /// Leo 2026-11-11: "idk why those github links opened in a 3rd col instead of just to the right..."; "i think it
    /// forgot that there was browser on the right side"; "like the opened github generated thing then github then blah
    /// etc idk". A link from the chat joins the nearest pane on its right that already holds a browser, whichever pane
    /// was focused last; only with none there does it split.
    private static func frames(_ columns: [[String]]) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (x, column) in columns.enumerated() {
            for (y, pane) in column.enumerated() { frames[pane] = CGRect(x: x * 500, y: y * 400, width: 480, height: 380) }
        }
        return frames
    }

    private static func nearest(_ columns: [[String]], browsers: Set<String>, frames: [String: CGRect]? = nil,
                                from source: String = "chat") -> String? {
        Rule.nearestHolder(of: .browser, source: source, columns: columns, frames: frames ?? Self.frames(columns),
                           holds: { pane, kind in kind == .browser && browsers.contains(pane) })
    }

    @Test func aChatWithABrowserOnItsRightOpensTheLinkThere() {
        let columns = [["chat"], ["browser"]]
        let holder = Self.nearest(columns, browsers: ["browser"])
        #expect(holder == "browser")
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: "browser", column: ["browser"],
                                                   sourceWidth: 1400, width: { _ in 700 }, kind: .browser, holder: holder)
                == .pane("browser"))
    }

    /// The history Leo hit: an earlier link made a far column and took the focus, so it was the chat's "right side"
    /// (the most recently focused strip pane); the browser right beside the chat still wins.
    @Test func anEarlierLinksFarColumnNeverWinsOverTheBrowserBesideTheChat() {
        let columns = [["chat"], ["middle"], ["far"]]
        let holder = Self.nearest(columns, browsers: ["middle", "far"])
        #expect(holder == "middle")
        // `right` is what recency picked (the far column); the holder overrides it.
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: "far", column: ["middle"],
                                                   sourceWidth: 1400, width: { _ in 700 }, kind: .browser, holder: holder)
                == .pane("middle"))
        // A terminal beside the chat: the nearest browser is the far one, never a split below the terminal.
        #expect(Self.nearest(columns, browsers: ["far"]) == "far")
    }

    @Test func aChatWithATerminalOnItsRightKeepsTheLowerSplit() {
        let columns = [["chat"], ["terminal"]]
        let holder = Self.nearest(columns, browsers: [])
        #expect(holder == nil)
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: "terminal", column: ["terminal"],
                                                   sourceWidth: 1400, width: { _ in 700 }, kind: .browser, holder: holder)
                == .splitBelow(of: "terminal"))
    }

    @Test func aChatAloneSplitsRight() {
        let holder = Self.nearest([["chat"]], browsers: [])
        #expect(holder == nil)
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: nil, sourceWidth: 1400, kind: .browser, holder: holder)
                == .splitRight(of: "chat"))
    }

    @Test func aChatBetweenTwoBrowsersOpensInTheOneOnItsRight() {
        #expect(Self.nearest([["left"], ["chat"], ["right"]], browsers: ["left", "right"]) == "right")
    }

    @Test func aBrowserOnlyOnTheLeftIsNotUsed() {
        let holder = Self.nearest([["browser"], ["chat"]], browsers: ["browser"])
        #expect(holder == nil)
        #expect(Rule(setting: .splitRight).target(source: "chat", takesTabs: true, right: nil, sourceWidth: 1400, kind: .browser, holder: holder)
                == .splitRight(of: "chat"))
    }

    /// A browser pane restored from the last launch, before its first layout (no frame yet), or a strip column scrolled
    /// out of view: the layout's column order still finds it.
    @Test func aRestoredBrowserPaneWithNoFrameYetIsStillFound() {
        let columns = [["chat"], ["restored"], ["far"]]
        var frames = Self.frames(columns)
        frames["restored"] = nil
        #expect(Self.nearest(columns, browsers: ["restored", "far"], frames: frames) == "restored")
        #expect(Self.nearest(columns, browsers: ["restored", "far"], frames: [:]) == "restored")
    }

    /// No strip: one column split side by side. Frames order it; a pane below the chat is not on its right.
    @Test func aPlainSplitReadsByFrames() {
        let frames: [String: CGRect] = [
            "chat": CGRect(x: 0, y: 0, width: 480, height: 380), "below": CGRect(x: 0, y: 400, width: 480, height: 380),
            "middle": CGRect(x: 500, y: 0, width: 480, height: 780), "far": CGRect(x: 1000, y: 0, width: 480, height: 780),
        ]
        let columns = [["chat", "below", "middle", "far"]]
        #expect(Self.nearest(columns, browsers: ["below", "middle", "far"], frames: frames) == "middle")
        #expect(Self.nearest(columns, browsers: ["below", "far"], frames: frames) == "far")
        #expect(Self.nearest(columns, browsers: ["below"], frames: frames) == nil)
    }

    /// Within the nearest column, the lowest pane holding a browser, as design/pane-placement.md's same-kind reuse.
    @Test func theNearestColumnAnswersWithItsLowestBrowser() {
        #expect(Self.nearest([["chat"], ["top", "low"], ["far"]], browsers: ["top", "low", "far"]) == "low")
        #expect(Self.nearest([["chat"], ["terminal", "browser"]], browsers: ["browser"]) == "browser")
    }

    /// Same Pane keeps its tab in the source.
    @Test func samePaneStillOpensInTheSource() {
        #expect(Rule(setting: .samePane).target(source: "chat", takesTabs: true, right: "browser", kind: .browser, holder: "browser")
                == .pane("chat"))
    }

    /// The GitHub page (a chat's pull request link) is a browser page: its pane is the browser beside the chat.
    @MainActor @Test func theGitHubPageCountsAsABrowserPane() {
        func tab(_ kind: TabKind, page: String? = nil) -> TabModel {
            var snapshot = TabSnapshot(surface: 1, kind: kind, cwd: nil)
            if let page { snapshot.conversation = ConversationTabRef(page: page, route: "https://github.com/o/r/pull/1") }
            return TabModel(snapshot)
        }
        #expect(LinkOpener.holds(tabs: [tab(.conversation, page: "github")], .browser))
        #expect(LinkOpener.holds(tabs: [tab(.browser)], .browser))
        #expect(!LinkOpener.holds(tabs: [tab(.conversation, page: "files")], .browser))
        #expect(!LinkOpener.holds(tabs: [tab(.pty)], .browser))
        #expect(!LinkOpener.holds(tabs: [tab(.conversation, page: "github")], .terminal))
    }
}
