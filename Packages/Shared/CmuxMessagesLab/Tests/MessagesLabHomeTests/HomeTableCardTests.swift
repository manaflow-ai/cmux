import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// Tables in the Chief's replies (Leo 2026-10-20, "isn't this kind of ugly?"): a pipe table breaks
/// out of the bubble as a full-width card with real column widths, and an assignment table (design
/// PR / what it builds / who) is the Chief's plan card with owner chips, states and pull requests.
@Suite(.serialized) struct HomeTableCardTests {
    /// Chief chat message 137, 2026-10-20, as the Chief wrote it.
    static let reply = """
    I've handed out all six first PRs from the [nightly-train design](https://github.com/teamleaderleo/leo-workspace/pull/624). Nothing has landed yet.

    | Design PR | What it builds | Who |
    |---|---|---|
    | 1 + 2 | Lasting canary results, a planner for each night's build, and a workflow that reverts the newest change or bisects to find the bad one, plus the guard for promoting a build to main | **a12** (new; workspace "a12 · Nightly train and canary", group cmux-next app) |
    | 3 | A map from changed files to the tests that cover them, and fast checks for each change in the batch | a7, added to its ship-guard work |
    | 4 | A banner that offers the roll-back from [#22590](https://github.com/manaflow-ai/cmux/pull/22590) when a build was pulled | a4, once #22590 lands |
    | 5 | Canary checks that only report for the first week, then block bad builds, and a fix-forward run on every pull | **a13** (new; workspace "a13 · Train canary verification", group cmux-next app) |
    | 6 | An in-app engine that runs agent workflows, saves their steps and can resume them, plus a sidebar group for running workflows | **a14** (new; workspace "a14 · Native workflows runtime", group Agents & routing) |

    The design asked for a separate session for PR 6. I gave it to a14 instead, so it stays with the rest of the work.
    """

    init() {
        HomeMarkdownPolicy.install()
        HomeTableRowProvider.isOn = true
        HomePlanRowProvider.plan = .empty
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
    }

    static func table(_ text: String) -> HomeTable? {
        for case .table(let table, _) in HomeTableSplitter().segments(in: text) { return table }
        return nil
    }

    @Test func theReplysTableIsCutOutWithTheTextAroundIt() throws {
        let segments = HomeTableSplitter().segments(in: Self.reply)
        #expect(segments.count == 3)
        guard case .text(let before) = segments[0], case .table(let table, let raw) = segments[1], case .text(let after) = segments[2] else {
            Issue.record("expected text, table, text: \(segments)")
            return
        }
        #expect(before.contains("Nothing has landed yet."))
        #expect(after.contains("I gave it to a14 instead"))
        #expect(table.header == ["Design PR", "What it builds", "Who"])
        #expect(table.rows.count == 5)
        #expect(raw.hasPrefix("| Design PR |"))
        #expect(raw.hasSuffix("group Agents & routing) |"))
    }

    @Test func aTableInACodeFenceStaysCode() {
        let text = "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```"
        #expect(HomeTableSplitter().segments(in: text) == [.text(text)])
    }

    @Test func pipesInCodeSpansAndEscapesStayInTheirCell() {
        let table = Self.table("| cmd | note |\n|:--|--:|\n| `a | b` | x \\| y |")
        #expect(table?.rows == [["`a | b`", "x | y"]])
        #expect(table?.alignments == [.leading, .trailing])
    }

    @Test func aLineWithPipesButNoDelimiterRowIsText() {
        #expect(Self.table("a | b\nc | d") == nil)
    }

    @Test func theReplysTableIsAPlanCard() throws {
        let table = try #require(Self.table(Self.reply))
        let card = try #require(HomePlanCard(table))
        #expect(card.rows.map(\.owner) == ["a12", "a7", "a4", "a13", "a14"])
        #expect(card.rows.map(\.key) == ["1 + 2", "3", "4", "5", "6"])
        #expect(card.rows[0].title.hasPrefix("Lasting canary results"))
        #expect(card.rows[0].ownerNote == "new; workspace \"a12 · Nightly train and canary\", group cmux-next app")
        #expect(card.rows[1].ownerNote == "added to its ship-guard work")
        #expect(card.rows[2].pullRequests == ["https://github.com/manaflow-ai/cmux/pull/22590"])
        #expect(card.rows[2].title == "A banner that offers the roll-back from #22590 when a build was pulled")
        // No status column: no state until the live plan has the step.
        #expect(card.states(in: .empty) == [nil, nil, nil, nil, nil])
    }

    @Test func theLivePlanGivesEachOwnersState() throws {
        let table = try #require(Self.table(Self.reply))
        let card = try #require(HomePlanCard(table))
        let plan = ChiefPlan(steps: [
            ChiefPlanStep(id: "a12", title: "Nightly train", owner: "a12", state: .working),
            ChiefPlanStep(id: "a4", title: "Updates", owner: "a4", state: .waitingOnCI,
                          pullRequests: [ChiefPlanPullRequest(url: "https://github.com/manaflow-ai/cmux/pull/22590", number: 22590)]),
            ChiefPlanStep(id: "a14", title: "Workflows", owner: "A14", state: .landed),
        ])
        #expect(card.states(in: plan) == [.working, nil, .waitingOnCI, nil, .landed])
    }

    @Test func aStatusColumnGivesTheWrittenState() throws {
        let table = try #require(Self.table("| Task | Owner | Status |\n|---|---|---|\n| Inspector | a10 | waiting on CI |\n| Pet dock | a11 | landed |\n| Docs | a5 | in progress |"))
        let card = try #require(HomePlanCard(table))
        #expect(card.rows.map(\.written) == [.waitingOnCI, .landed, nil])
        #expect(card.rows.map(\.title) == ["Inspector", "Pet dock", "Docs"])
    }

    @Test func aTableWithoutOwnersIsATableCard() throws {
        let table = try #require(Self.table("| Check | Time |\n|---|---|\n| guards | 4m |\n| swift test | 12m |"))
        #expect(HomePlanCard(table) == nil)
        guard case .custom(let part)? = HomeTableRowProvider.part(table, raw: "raw") else {
            Issue.record("no card")
            return
        }
        #expect(part.kind == HomeTableRowProvider.kind)
    }

    @Test func aColumnOfPaperSizesIsNotAPlan() throws {
        let table = try #require(Self.table("| Size | mm |\n|---|---|\n| A4 | 210 × 297 |\n| A3 | 297 × 420 |"))
        #expect(HomePlanCard(table) == nil)
    }

    @Test func aWrappedCellIsAsTallAsTheLinesItDraws() {
        let text = HomeTableGrid.attributed(HomeTableCell(markdown: "Lasting canary results, a planner for each night's build, and a workflow that reverts"),
                                            header: false)
        let lines = HomeCardDraw.lines(text, width: 60)
        #expect(lines.count >= 4)
        #expect(HomeTableGrid.textHeight(text, width: 60) == lines.reduce(0) { $0 + $1.height })
    }

    @Test func ownerIDsAreSubagentIdsOnly() {
        #expect(HomePlanCard.ownerID("a12") == "a12")
        #expect(HomePlanCard.ownerID("A7, added") == "a7")
        #expect(HomePlanCard.ownerID("a4b") == nil)
        #expect(HomePlanCard.ownerID("agent") == nil)
        #expect(HomePlanCard.ownerID("a") == nil)
    }

    @Test func theReplyMapsToTextThePlanCardAndText() {
        let parts = HomeMapping.parts(.text(Self.reply), markdown: true)
        let kinds = parts.map { part -> String in
            if case .custom(let c) = part { return c.kind }
            return "text"
        }
        #expect(kinds.filter { $0 == HomePlanRowProvider.kind }.count == 1)
        #expect(kinds.first == "text")
        #expect(kinds.last == "text")
        // Copy reads the table as written.
        let card = parts.compactMap { part -> CustomPart? in if case .custom(let c) = part { return c } else { return nil } }.first
        #expect(card.flatMap { HomePlanRowProvider.payload($0)?.raw }?.contains("| 3 | A map from changed files") == true)
    }

    @Test func withRichTablesOffTheTableStaysInTheBubble() {
        HomeTableRowProvider.isOn = false
        defer { HomeTableRowProvider.isOn = true }
        let parts = HomeMapping.parts(.text(Self.reply), markdown: true)
        #expect(!parts.contains { if case .custom = $0 { return true } else { return false } })
    }

    @Test func peoplesTablesStayText() {
        let parts = HomeMapping.parts(.text("| a | b |\n|---|---|\n| 1 | 2 |"), markdown: false)
        #expect(!parts.contains { if case .custom = $0 { return true } else { return false } })
    }

    @Test func columnsKeepTheirNaturalWidthsWhenTheyFit() {
        #expect(HomeTableColumns.widths(natural: [60, 200, 90], available: 600) == [60, 200, 90])
    }

    @Test func wideColumnsShareTheRoomNarrowOnesKeepTheirs() {
        let widths = HomeTableColumns.widths(natural: [70, 900, 500], available: 700)
        #expect(widths[0] == 70)
        #expect(widths.reduce(0, +) <= 700)
        // The wide ones in proportion to their natural widths.
        #expect(widths[1] > widths[2])
        #expect(widths[2] >= HomeTableColumns.minColumn)
    }

    @Test func theReplysTableIsAsWideAsTheChatNotTheBubble() throws {
        let table = try #require(Self.table(Self.reply))
        let grid = HomeTableGrid(table, available: 760)
        // A bubble is at most Fixture.maxTextWidth (358 pt); the card's What column alone is wider.
        #expect(grid.cardWidth > Fixture.maxTextWidth)
        #expect(grid.cardWidth <= 760)
        #expect(grid.widths[1] > grid.widths[0] && grid.widths[1] > grid.widths[2] / 2)
        // Five body rows and the header, each at least one line tall.
        #expect(grid.heights.count == 6)
        #expect(grid.heights.allSatisfy { $0 >= Fixture.bodyFont.pointSize })
    }
}
