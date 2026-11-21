import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// https://github.com/manaflow-ai/cmux/issues/48598: a drag reorder in the sidebar taps the trackpad as Aside does,
/// the alignment tap each time the drop slot changes and the level-change tap as the drop lands, and
/// `sidebar.reorderHaptics` off plays none. A real list (`SidebarDragStartKeepsRowsTests.list`), dragged with
/// `updateDrag` and dropped with `finishDrag`; the taps the drag plays are recorded instead of played.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarReorderHapticsTests {
    final class Taps {
        var patterns: [NSHapticFeedbackManager.FeedbackPattern] = []
        var alignments: Int { patterns.filter { $0 == .alignment }.count }
        var drops: Int { patterns.filter { $0 == .levelChange }.count }
    }

    /// Runs `body` on the five-row list with `sidebar.reorderHaptics` at `enabled` (put back after), the list's taps
    /// recorded instead of played.
    static func recording(document: Bool = false, enabled: Bool = true, _ body: (SidebarListView, Taps) throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let saved = DesignSettings.shared.sidebarSections.reorderHaptics
        DesignSettings.shared.sidebarSections.reorderHaptics = enabled
        defer { DesignSettings.shared.sidebarSections.reorderHaptics = saved }
        let (list, window) = SidebarDragStartKeepsRowsTests.list(document: document)
        defer { window.close() }
        let taps = Taps()
        list.reorderHaptics.perform = { [taps] in taps.patterns.append($0) }
        try body(list, taps)
    }

    /// Lifts `c` (third of five) and moves it down past `d` and `e` in small steps: the number of times its drop
    /// slot changed, as the list resolved it after each move.
    static func dragDown(_ list: SidebarListView) throws -> Int {
        let (drag, start) = try SidebarDragStartKeepsRowsTests.lift(list)
        var slot = drag.hapticSlot
        var changes = 0
        for step in 1...30 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + CGFloat(step) * 3), to: nil))
            let now = drag.hapticSlot
            // The first slot a drag has is where it starts (a document drag resolves it on its first move): no tap.
            if let now, now != slot { changes += slot == nil ? 0 : 1; slot = now }
        }
        return changes
    }

    /// One alignment tap per slot change, none at the lift or for a move that keeps the slot; the drop taps once.
    @Test(arguments: [false, true]) func aReorderTapsAtEachSlotAndOnTheDrop(_ document: Bool) throws {
        try Self.recording(document: document) { list, taps in
            let changes = try Self.dragDown(list)
            #expect(changes >= 2, "the drag down past two rows changed its slot \(changes) times")
            #expect(taps.alignments == changes, "\(taps.alignments) alignment taps for \(changes) slot changes")
            #expect(taps.drops == 0, "a move played the drop tap")
            guard !document else { return list.cancelDrag() } // the fixture's document takes no intent: its drop lands nothing
            list.finishDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            #expect(taps.drops == 1, "the drop played \(taps.drops) level-change taps")
            #expect(taps.patterns.last == .levelChange, "the drop's tap is not the last: \(taps.patterns)")
        }
    }

    /// A drag that is cancelled lands nothing: no drop tap.
    @Test func aCancelledDragPlaysNoDropTap() throws {
        try Self.recording { list, taps in
            _ = try Self.dragDown(list)
            list.cancelDrag()
            #expect(taps.drops == 0, "a cancel played the drop tap")
        }
    }

    /// A row lifted and released in its own slot keeps the order: no slot tap and no drop tap.
    @Test func aReleaseWhereItStartedPlaysNothing() throws {
        try Self.recording { list, taps in
            let (_, start) = try SidebarDragStartKeepsRowsTests.lift(list)
            for dy in [CGFloat(2), 4, 2, 0] {
                list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy), to: nil))
            }
            list.finishDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            #expect(taps.patterns.isEmpty, "a release in place tapped: \(taps.patterns)")
        }
    }

    /// `sidebar.reorderHaptics` off: the same drag and drop play nothing.
    @Test func theSettingOffPlaysNothing() throws {
        try Self.recording(enabled: false) { list, taps in
            let changes = try Self.dragDown(list)
            #expect(changes >= 2, "the drag changed its slot \(changes) times")
            list.finishDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            #expect(taps.patterns.isEmpty, "taps with the setting off: \(taps.patterns)")
        }
    }
}
