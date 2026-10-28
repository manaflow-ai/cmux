import CoreGraphics
@testable import CmuxNextTabs
import Testing

/// A tab dropped from another strip resolves by the pointer: past a tab's midpoint it lands after
/// that tab, short of it before. A narrow tab used to need the pointer past its trailing edge, so
/// an 85% drop on a one-letter tab still landed before it.
@Suite struct TabDropPointerSlotTests {
    @Test(arguments: [(0.15, 0), (0.85, 1)])
    func aDropLandsOnTheSideOfTheMidpointThePointerIsOn(fraction: Double, expectedIndex: Int) {
        let width: CGFloat = 48
        let entries = [
            TabLayoutSlot(id: TabID("narrow"), x: 0, width: width, isPinned: false),
            TabLayoutSlot(id: TabID("next"), x: width, width: 180, isPinned: false),
        ]
        let resolved = TabGroupDropMath.resolveTab(
            entries: entries,
            start: 0,
            draggedMinX: width * fraction,
            currentGroup: nil,
            hysteresis: 0.3 * 180
        )
        #expect(resolved == TabGroupDropResolution(index: expectedIndex, groupID: nil))
    }
}
