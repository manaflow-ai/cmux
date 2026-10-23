import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Leo 2026-10-22: "the tab unread + simultaneous ongoing thing feels I weird idk if there's a way
/// to combine + the spacing is off". A tab that is unread while its agent (or page) works drew two
/// marks side by side, the spinner and the unread dot. It draws one: the spinner in the unread
/// dot's slot while work runs, and the dot in that same place once the work ends. Every state mark
/// sits centered in one slot the spinner's size, so a dot, a spinner and the dot that follows it
/// line up, and the slot keeps the title-to-x gap from the x.
@MainActor @Suite(.serialized) struct TabWorkingUnreadMarkTests {
    enum Kind: String, CaseIterable, Sendable {
        case terminal, agentChat, browser
    }

    private static func icon(_ kind: Kind) -> TabIcon {
        switch kind {
        case .terminal: .icon(.terminal)
        case .agentChat: .agentMark("claude")
        case .browser: .icon(.browser)
        }
    }

    private static func item(_ kind: Kind, unread: Bool, busy: Bool) -> TabItem {
        var item = TabItem(id: TabID(kind.rawValue), title: "Fix the login bug", icon: icon(kind), isUnread: unread, isBusy: busy)
        if busy { item.indicator = kind == .browser ? .busy(progress: nil) : .working(progress: nil) }
        return item
    }

    private static func cell(_ kind: Kind, unread: Bool = true, busy: Bool = true, selected: Bool = true, width: CGFloat = 220) -> TabCell {
        let cell = TabCell(item: item(kind, unread: unread, busy: busy))
        cell.isSelected = selected
        cell.frame = CGRect(x: 0, y: 0, width: width, height: 32)
        cell.layoutLayers()
        return cell
    }

    /// The marks a tab draws now: the unread or status dot, a status glyph and the busy indicator.
    private static func marks(_ cell: TabCell) -> [String: CGRect] {
        var marks: [String: CGRect] = [:]
        if let badge = cell.badgeLayer, badge.opacity > 0, !badge.isHidden { marks["unread"] = badge.frame }
        if let glyph = cell.statusGlyphLayer, glyph.layer.opacity > 0, !glyph.layer.isHidden { marks["status"] = glyph.frame }
        if let spinner = cell.spinnerLayer, spinner.layer.opacity > 0, !spinner.layer.isHidden { marks["loading"] = spinner.frame }
        return marks
    }

    /// The spinner's side in the trailing cluster, which is the state slot's width.
    private static func slot(_ cell: TabCell) -> CGFloat { cell.metrics.iconSize - 2 * Metrics.space1 }

    @Test(arguments: Kind.allCases) func anUnreadTabAtWorkDrawsOneMarkTheSpinner(kind: Kind) throws {
        for selected in [false, true] {
            let cell = Self.cell(kind, selected: selected)
            let marks = Self.marks(cell)
            #expect(marks.count == 1, "\(kind) selected \(selected): \(marks.keys.sorted()) draw, one mark expected")
            let spinner = try #require(marks["loading"], "\(kind): the one mark is not the spinner")
            #expect(spinner.minX > cell.bounds.midX, "\(kind): the spinner is not on the trailing side (\(spinner))")
        }
    }

    /// The slot ends the title-to-x gap before the x (selected tab) or at the trailing inset.
    @Test(arguments: Kind.allCases) func theSpinnerSitsInTheStateSlotAtTheEnd(kind: Kind) throws {
        let selected = Self.cell(kind, selected: true)
        let close = try #require(selected.closeButtonRect, "\(kind): a selected tab shows its x")
        let spinner = try #require(Self.marks(selected)["loading"])
        #expect(abs(spinner.maxX - (close.minX - selected.metrics.titleCloseSpacing)) < 0.51,
                "\(kind): the spinner ends at \(spinner.maxX), the slot at \(close.minX - selected.metrics.titleCloseSpacing)")
        #expect(abs(spinner.width - Self.slot(selected)) < 0.01, "\(kind): spinner \(spinner.width) wide, slot \(Self.slot(selected))")

        let resting = Self.cell(kind, selected: false)
        if resting.closeButtonRect == nil {
            let pill = resting.pillFrameInCell
            let spinner = try #require(Self.marks(resting)["loading"])
            #expect(abs(spinner.maxX - (pill.width - resting.metrics.contentTrailingInset)) < 0.51,
                    "\(kind): a resting tab's spinner ends at \(spinner.maxX), not the trailing inset")
        }
    }

    /// When the work ends, the unread dot shows where the spinner was: same center, nothing moves.
    @Test(arguments: Kind.allCases) func theDotTakesTheSpinnersPlaceWhenWorkEnds(kind: Kind) throws {
        let cell = Self.cell(kind)
        let spinner = try #require(Self.marks(cell)["loading"])
        cell.update(item: Self.item(kind, unread: true, busy: false))
        let marks = Self.marks(cell)
        #expect(marks.count == 1, "\(kind): \(marks.keys.sorted()) after the work ended")
        let dot = try #require(marks["unread"], "\(kind): no unread dot after the work ended")
        #expect(abs(dot.midX - spinner.midX) < 0.51 && abs(dot.midY - spinner.midY) < 0.51,
                "\(kind): the dot \(dot) is not centered where the spinner \(spinner) was")
        #expect(abs(dot.width - cell.metrics.badgeSize) < 0.01, "\(kind): the dot is \(dot.width) wide")
    }

    /// An unread tab that never worked puts its dot at the same center as a working neighbor's spinner.
    @Test func dotsAndSpinnersLineUpAcrossTabs() throws {
        let working = Self.cell(.terminal, unread: false, busy: true, selected: false)
        let unread = Self.cell(.terminal, unread: true, busy: false, selected: false)
        let spinner = try #require(Self.marks(working)["loading"])
        let dot = try #require(Self.marks(unread)["unread"])
        #expect(abs(dot.midX - spinner.midX) < 0.51, "dot center \(dot.midX), spinner center \(spinner.midX)")
    }

    /// A tab that shows no title (a pinned one) draws the spinner on its icon: no unread dot on the
    /// icon's corner beside it.
    @Test func anIconOnlyUnreadTabAtWorkDrawsOnlyTheSpinner() throws {
        var item = Self.item(.terminal, unread: true, busy: true)
        item.isPinned = true
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 40, height: 32)
        cell.layoutLayers()
        let marks = Self.marks(cell)
        #expect(marks.keys.sorted() == ["loading"], "an icon-only tab draws \(marks.keys.sorted())")
    }
}
