@testable import CmuxTabsKit
import Testing

/// (+) on device (cmux-next newtab-dup-device.mp4): the source listed the new
/// tab before `createTab` returned, and the placeholder moved to the next
/// slot, so the grid showed two new cards for about 100 ms.
struct NewTabSlotTests {
    private let slot = NewTabSlot(baseline: ["t:a", "b1"])

    @Test func placeholderStandsInUntilTheHostListsTheTab() {
        let ids = ["t:a", "b1"]
        #expect(slot.showsPlaceholder(in: ids))
        #expect(slot.placeholderIndex(in: ids) == 2)
        #expect(slot.cardCount(in: ids) == 3)
        #expect(slot.zoomIndex(in: ids) == 2)
    }

    /// The event arrives before the reply: the real card takes the
    /// placeholder's slot in place; the grid still has exactly three cards.
    @Test func eventBeforeReplyReconcilesInPlace() {
        let before = ["t:a", "b1"]
        let after = ["t:a", "b1", "b2"]
        #expect(slot.created(in: after) == "b2")
        #expect(!slot.showsPlaceholder(in: after))
        #expect(slot.cardCount(in: after) == slot.cardCount(in: before))
        #expect(slot.zoomIndex(in: after) == slot.zoomIndex(in: before))
    }

    /// A tab closed on the Mac meanwhile: the placeholder follows the list.
    @Test func baselineTabClosedMeanwhile() {
        let ids = ["t:a"]
        #expect(slot.showsPlaceholder(in: ids))
        #expect(slot.placeholderIndex(in: ids) == 1)
        #expect(slot.cardCount(in: ids) == 2)
        #expect(slot.zoomIndex(in: ["t:a", "b2"]) == 1)
    }

    /// A refused create: nothing new is ever listed.
    @Test func refusedCreateKeepsOnlyThePlaceholder() {
        #expect(slot.created(in: slot.baseline) == nil)
        #expect(slot.cardCount(in: slot.baseline) == 3)
    }
}
