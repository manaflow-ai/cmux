import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
import Testing

/// Every open on the right of a pane takes its turn beside that pane (``RightColumnTurns``),
/// deciding its place from the column as the open before it left it. Reviews of #28044 at c15e0d89 and
/// e954bd85 each found two opens that read one column before either had landed (two links; a folder and
/// a link), so both split below the same pane and three panes stood on the right. Each fix covered one
/// opener and the next review found another; the turn is now the one place every opener goes through.
@MainActor @Suite(.serialized) struct RightColumnTurnTests {
    let turns = RightColumnTurns()
    /// The openers that place on the right, by the entry point each goes through.
    enum Kind: String, CaseIterable {
        case link, file, browser, folder // LinkOpener.open / openFolder
        case subagent, sideChat, sessionInfo // AgentTabStore.openOnRight
    }

    /// A chat's right column: opens land later, when `land` runs, as a daemon's move does.
    @MainActor final class Column {
        var panes: [String] = []
        var events: [String] = []
        var landings: [@MainActor () -> Void] = []
        let source: LayoutPaneID
        let turns: RightColumnTurns

        init(_ source: String, panes: [String] = [], turns: RightColumnTurns) {
            self.source = LayoutPaneID(source)
            self.turns = turns
            self.panes = panes
        }

        /// An open of `kind`, through the turn: it decides from the column it finds, and its turn ends when it lands.
        func open(_ kind: Kind) {
            turns.serially(beside: source) { [self] done in
                let decision = RightColumnPlacement.decide(sourceWidth: 1400, column: panes, width: { _ in 700 })
                switch decision {
                case .splitRight:
                    landings.append { [self] in panes = ["right"]; events.append("\(kind.rawValue): split right"); done() }
                case .splitBelow(let pane):
                    landings.append { [self] in panes.append("lower"); events.append("\(kind.rawValue): split below \(pane)"); done() }
                case .tab(let pane):
                    events.append("\(kind.rawValue): tab in \(pane ?? "chat")")
                    done()
                }
            }
        }

        /// Lands every open under way, oldest first, until none is left.
        func landAll() {
            while !landings.isEmpty { landings.removeFirst()() }
        }
    }

    @Test func aTurnWaitsForTheOneUnderWayAndRunsWhenItEnds() {
        let source = LayoutPaneID("turn-basic")
        var ran: [String] = []
        var first: (@MainActor () -> Void)?
        let firstRan = turns.serially(beside: source) { done in ran.append("first"); first = done }
        let secondRan = turns.serially(beside: source) { done in ran.append("second"); done() }
        #expect(firstRan)
        #expect(!secondRan, "a second open ran beside one still moving")
        #expect(ran == ["first"])
        // Another pane's opens are not held up.
        let otherRan = turns.serially(beside: LayoutPaneID("turn-other")) { done in ran.append("other"); done() }
        #expect(otherRan)
        first?()
        first?()
        #expect(ran == ["first", "other", "second"])
        #expect(!turns.isBusy(beside: source), "a turn that ended twice left its source held")
    }

    /// Every pair of openers, each kind with each, from an empty right column and from one pane on the
    /// right, both asked for before either lands: never more than two panes on the right.
    @Test(arguments: [[String](), ["diff"]])
    func everyPairOfOpenersLeavesAtMostTwoPanes(startingWith start: [String]) {
        for first in Kind.allCases {
            for second in Kind.allCases {
                let column = Column("pair-\(first)-\(second)-\(start.count)", panes: start, turns: turns)
                column.open(first)
                column.open(second)
                column.landAll()
                #expect(column.panes.count <= 2, "\(first) then \(second) from \(start): \(column.panes), \(column.events)")
                let expected = start.isEmpty
                    ? ["\(first.rawValue): split right", "\(second.rawValue): split below right"]
                    : ["\(first.rawValue): split below diff", "\(second.rawValue): tab in lower"]
                #expect(column.events == expected, "\(first) then \(second) from \(start)")
            }
        }
    }

    /// All the openers at once, mixed: one split right, one split below it, then every other is a tab in the lower pane.
    @Test func everyOpenerAtOnceFillsOneColumn() {
        let column = Column("mixed", turns: turns)
        for kind in Kind.allCases + Kind.allCases.reversed() { column.open(kind) }
        column.landAll()
        #expect(column.panes == ["right", "lower"])
        #expect(column.events.filter { $0.contains("split") }.count == 2)
        #expect(column.events.count == Kind.allCases.count * 2)
    }
}
