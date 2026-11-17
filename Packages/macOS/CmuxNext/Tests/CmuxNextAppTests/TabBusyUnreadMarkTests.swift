import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Leo 2026-10-22 (ask-a8b97f1201): "the tab unread + simultaneous ongoing thing feels weird idk if there is a way
/// to combine + the spacing is off". A busy tab with unread output draws one mark in the status slot, not the
/// unread dot with the spinner squeezed in beside it; when the work ends the dot takes that same slot, so the
/// title's end never moves.
@MainActor @Suite(.serialized) struct TabBusyUnreadMarkTests {
    private static let id = TabID("busy-unread")

    private static func item(busy: Bool, unread: Bool = true) -> TabItem {
        var item = TabItem(id: id, title: "A long enough page title to clip", icon: .icon(.browser), isUnread: unread, isBusy: busy)
        if busy { item.indicator = .busy(progress: nil) }
        return item
    }

    private static func cell(busy: Bool, look: TabBusyUnreadMark? = nil) -> TabCell {
        let cell = TabCell(item: item(busy: busy))
        if let look {
            var metrics = cell.metrics
            metrics.busyUnreadMark = look
            cell.metrics = metrics
        }
        cell.scale = 2
        cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        cell.layoutLayers()
        return cell
    }

    private static func shows(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        return !layer.isHidden && layer.opacity > 0 && layer.superlayer != nil
    }

    /// The marks a person sees side by side: the dot and the spinner count as two unless one sits inside the other.
    private static func separateMarks(_ cell: TabCell) -> Int {
        let dot = shows(cell.badgeLayer) ? cell.badgeLayer?.frame : nil
        let spinner = shows(cell.spinnerLayer?.layer) ? cell.spinnerLayer?.frame : nil
        switch (dot, spinner) {
        case let (dot?, spinner?): return spinner.contains(dot) ? 1 : 2
        case (nil, nil): return 0
        default: return 1
        }
    }

    @Test func theDefaultCombinesTheUnreadDotAndTheSpinnerIntoOneMark() {
        #expect(TabTunables.busyUnreadMark.defaultValue != .pair, "the default still draws the dot and the spinner side by side")
        let cell = Self.cell(busy: true)
        #expect(Self.separateMarks(cell) == 1, "a busy unread tab draws \(Self.separateMarks(cell)) marks")
    }

    @Test(arguments: TabBusyUnreadMark.allCases.filter { $0 != .pair })
    func everyCombinedLookDrawsOneMarkInTheStatusSlot(look: TabBusyUnreadMark) throws {
        let cell = Self.cell(busy: true, look: look)
        #expect(Self.separateMarks(cell) == 1, "\(look): \(Self.separateMarks(cell)) marks")
        let spinner = try #require(cell.spinnerLayer?.frame, "\(look): no busy indicator")
        // The status slot is the x's slot: the hovered x takes the mark's place.
        let slotMidX = cell.bounds.width - cell.metrics.contentTrailingInset - cell.metrics.closeButtonSize / 2
        #expect(abs(spinner.midX - slotMidX) <= 0.5, "\(look): the mark is at \(spinner.midX), the slot's middle at \(slotMidX)")
    }

    @Test(arguments: TabBusyUnreadMark.allCases.filter { $0 != .pair })
    func theTitleEndHoldsWhenTheWorkEnds(look: TabBusyUnreadMark) throws {
        let cell = Self.cell(busy: true, look: look)
        let busyTitleEnd = try #require(cell.titleFade.geometry?.visibleWidth)
        let busyMark = try #require(cell.spinnerLayer?.frame)
        cell.update(item: Self.item(busy: false))
        cell.layoutLayers()
        let dot = try #require(cell.badgeLayer?.frame, "\(look): no unread dot once the work ended")
        #expect(abs(dot.midX - busyMark.midX) <= 0.5, "\(look): the dot lands at \(dot.midX), the mark was at \(busyMark.midX)")
        let idleTitleEnd = try #require(cell.titleFade.geometry?.visibleWidth)
        #expect(idleTitleEnd == busyTitleEnd, "\(look): the title's visible width moved from \(busyTitleEnd) to \(idleTitleEnd)")
    }

    @Test func thePairLookKeepsTheOldTwoMarks() {
        let cell = Self.cell(busy: true, look: .pair)
        #expect(Self.separateMarks(cell) == 2)
    }

    @Test func aStatusStillShowsBesideTheSpinner() {
        var item = Self.item(busy: true)
        item.status = .needsInput
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        cell.layoutLayers()
        // The status draws as the dot, or as a status icon set's glyph.
        #expect(Self.shows(cell.badgeLayer) || Self.shows(cell.statusGlyphLayer?.layer), "a needs-input mark gave way to the spinner")
        #expect(Self.shows(cell.spinnerLayer?.layer), "the spinner gave way to the needs-input mark")
    }
}
