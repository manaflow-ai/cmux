import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Leo 2026-11-19 (taste build 5, `experiments.agentBadges`): "Neutral count pill for unread agent messages or pending
/// approvals, width reserved so tabs never shift". An agent chat tab reserves the pill's slot whatever its count, so
/// its title ends in the same place at 0, 1, 42 and 120; off, the tab is the shipped one.
@MainActor @Suite(.serialized) struct TabCountPillTests {
    private static func cell(count: Int?, experiment: AgentBadgesExperiment, unread: Bool = false, hovered: Bool = false) -> TabCell {
        var item = TabItem(id: TabID("count-pill"), title: "An agent chat title long enough to run past the tab's end",
                           icon: .icon(.browser), isUnread: unread)
        item.agentBadgeCount = count
        let cell = TabCell(item: item)
        var metrics = cell.metrics
        metrics.agentBadges = experiment
        cell.metrics = metrics
        cell.scale = 2
        cell.frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        cell.isHovered = hovered
        cell.layoutLayers()
        return cell
    }

    private static func titleEnd(_ cell: TabCell) throws -> CGFloat {
        try #require(cell.titleFade.geometry?.visibleWidth, "the tab laid out no title")
    }

    @Test func theLabelCapsAt99() {
        #expect(TabCountPill.label(0) == nil)
        #expect(TabCountPill.label(1) == "1")
        #expect(TabCountPill.label(42) == "42")
        #expect(TabCountPill.label(99) == "99")
        #expect(TabCountPill.label(120) == "99+")
    }

    @Test func theSlotIsTheWidestPill() {
        let font = TabCountPill.font
        let slot = TabCountPill.slotWidth(font: font)
        for count in [1, 42, 120] {
            let label = TabCountPill.label(count) ?? ""
            #expect(TabCountPill.width(label, font: font) <= slot, "\(count) draws wider than the reserved slot")
        }
    }

    /// The reserved slot: the title's end is one place for every count, hovered or not.
    @Test(arguments: [false, true])
    func theTitleEndHoldsForEveryCount(hovered: Bool) throws {
        let ends = try [0, 1, 42, 120].map { try Self.titleEnd(Self.cell(count: $0, experiment: .pills, hovered: hovered)) }
        #expect(Set(ends).count == 1, "the title's visible width moved with the count: \(ends)")
        let rest = try Self.titleEnd(Self.cell(count: 3, experiment: .pills))
        let hover = try Self.titleEnd(Self.cell(count: 3, experiment: .pills, hovered: true))
        #expect(rest == hover, "hovering moved the title's end with the pill on")
    }

    /// A count that changes on a live cell keeps the title's end and the pill's trailing edge.
    @Test func aChangingCountMovesNothing() throws {
        let cell = Self.cell(count: 0, experiment: .pills)
        let end = try Self.titleEnd(cell)
        var trailing: Set<CGFloat> = []
        for count in [1, 42, 120, 0] {
            var item = cell.item
            item.agentBadgeCount = count
            cell.update(item: item)
            #expect(try Self.titleEnd(cell) == end, "count \(count) moved the title's end")
            let pill = try #require(cell.countPillLayer, "an agent tab with the experiment on has no pill layer")
            if count > 0 { trailing.insert(pill.frame.maxX) }
        }
        #expect(trailing.count == 1, "the pill's trailing edge moved: \(trailing)")
    }

    /// The pill stands in for the unread dot while it shows.
    @Test func thePillReplacesTheUnreadDot() {
        let on = Self.cell(count: 1, experiment: .pills, unread: true)
        #expect(on.badgeLayer == nil, "an agent tab with a count pill also drew the unread dot")
        #expect(on.countPillLayer?.opacity == 1)
        let off = Self.cell(count: 1, experiment: .off, unread: true)
        #expect(off.badgeLayer != nil, "off, the unread dot is gone")
    }

    /// Off, a count changes nothing: no pill, and the title ends where it ends on a tab with no count.
    @Test func offIsTheShippedTab() throws {
        let plain = try Self.titleEnd(Self.cell(count: nil, experiment: .off))
        for count in [0, 5, 120] {
            let cell = Self.cell(count: count, experiment: .off)
            #expect(cell.countPillLayer == nil)
            #expect(try Self.titleEnd(cell) == plain)
        }
        // A tab that is no agent chat reserves nothing with the experiment on.
        #expect(try Self.titleEnd(Self.cell(count: nil, experiment: .pills)) == plain)
    }
}
