@testable import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxNextHome

/// Dragging a pinned tile to a new place, or a row into the grid (Lawrence,
/// 2026-10-07: "pinned conversations must be reorderable by drag, like
/// Messages.app"). The grid's order is `HomePins.pinned`; default pins
/// (Chiefs) take a place in it the first time the user moves anything.
@Suite struct HomePinOrderTests {
    typealias T = HomeSidebarModelTests

    /// Four pins in the grid: the Chief (a default pin), then three user pins.
    static func fourPins() -> (rows: [InboxRow], pins: HomePins) {
        let rows = T.rows
        var pins = HomePins()
        pins.setPinned(true, rows[1])
        pins.setPinned(true, rows[2])
        pins.setPinned(true, rows[3])
        return (rows, pins)
    }

    static func grid(_ rows: [InboxRow], _ pins: HomePins) -> [String] {
        T.model(rows, pins: pins).pinned.map(\.id.rawValue)
    }

    @Test func theGridStartsWithUserPinsThenDefaultPins() {
        let (rows, pins) = Self.fourPins()
        #expect(Self.grid(rows, pins) == ["conv_lucas", "conv_group", "conv_aziz", "conv_chief"])
    }

    @Test func movingTheFirstTileToTheEnd() {
        var (rows, pins) = Self.fourPins()
        pins.place(ConversationID("conv_lucas"), at: 3, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins) == ["conv_group", "conv_aziz", "conv_chief", "conv_lucas"])
        rows = T.rows
        #expect(Self.grid(rows, pins) == ["conv_group", "conv_aziz", "conv_chief", "conv_lucas"], "the order does not depend on activity")
    }

    @Test func movingTheLastTileToTheFront() {
        let (rows, start) = Self.fourPins()
        var pins = start
        pins.place(ConversationID("conv_chief"), at: 0, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins) == ["conv_chief", "conv_lucas", "conv_group", "conv_aziz"])
        #expect(pins.unpinned.isEmpty)
    }

    @Test func movingAMiddleTile() {
        let (rows, start) = Self.fourPins()
        var pins = start
        pins.place(ConversationID("conv_group"), at: 2, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins) == ["conv_lucas", "conv_aziz", "conv_group", "conv_chief"])
        pins.place(ConversationID("conv_aziz"), at: 0, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins) == ["conv_aziz", "conv_lucas", "conv_group", "conv_chief"])
    }

    @Test func droppingARowIntoTheGridPinsItThere() {
        let (rows, start) = Self.fourPins()
        var pins = start
        pins.place(ConversationID("conv_old"), at: 1, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins) == ["conv_lucas", "conv_old", "conv_group", "conv_aziz", "conv_chief"])
        #expect(T.model(rows, pins: pins).rows.isEmpty)
    }

    @Test func aPreviouslyUnpinnedChiefDroppedIntoTheGridIsPinnedAgain() {
        let rows = T.rows
        var pins = HomePins()
        pins.setPinned(false, rows[0])
        #expect(Self.grid(rows, pins).isEmpty)
        pins.place(ConversationID("conv_chief"), at: 0, shown: [])
        #expect(Self.grid(rows, pins) == ["conv_chief"])
        #expect(pins.unpinned.isEmpty)
    }

    @Test func anOutOfRangeIndexClampsToTheEnds() {
        let (rows, start) = Self.fourPins()
        var pins = start
        pins.place(ConversationID("conv_group"), at: 99, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins).last == "conv_group")
        pins.place(ConversationID("conv_group"), at: -3, shown: T.model(rows, pins: pins).pinned.map(\.id))
        #expect(Self.grid(rows, pins).first == "conv_group")
    }
}
