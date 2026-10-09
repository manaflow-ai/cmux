import AppKit
import CmuxNextTabs
import Testing
@testable import CmuxNextApp

/// One spare per window (plans/cmux-next/new-tab.md section 2.2), as a pure
/// slot: warming and parked hand out the spare; an adopt or a drop empties
/// the slot, and only an empty slot starts a new spare.
@Suite struct NewTabSparePoolTests {
    @Test func theSlotHandsOutAtMostOneSpareAndRewarmsOnlyWhenEmpty() {
        var slot = NewTabSpareSlot<Int>()
        #expect(slot.take() == nil)
        #expect(slot.shouldWarm)
        slot.parked(1)
        #expect(!slot.shouldWarm)
        #expect(slot.take() == 1)
        #expect(slot.take() == nil)
        #expect(slot.shouldWarm)
        slot.parked(2)
        #expect(slot.drop() == 2)
        #expect(slot.shouldWarm)
        #expect(slot.drop() == nil)
    }

    /// Any sequence of events keeps at most one spare and never hands out
    /// the same spare twice.
    @Test func noEventSequenceDuplicatesASpare() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var slot = NewTabSpareSlot<Int>()
            var handedOut: Set<Int> = []
            var next = 0
            for _ in 0..<40 {
                switch Int.random(in: 0..<3, using: &generator) {
                case 0 where slot.shouldWarm:
                    next += 1
                    slot.parked(next)
                case 1:
                    if let spare = slot.take() { #expect(handedOut.insert(spare).inserted) }
                default:
                    if let spare = slot.drop() { #expect(!handedOut.contains(spare)) }
                }
                #expect(slot.count <= 1)
            }
        }
    }

    /// The parked spare is a live page (its cards hover and set the cursor even at alpha 0):
    /// it waits at its pane's size (the window's when no pane is known) but outside the window
    /// content, so the pointer never reaches it.
    @MainActor @Test func theParkedSpareIsNeverUnderThePointer() {
        for bounds in [NSRect(x: 0, y: 0, width: 1100, height: 720), NSRect(x: 0, y: 0, width: 5120, height: 2880)] {
            let frame = NewTabSpareParking.frame(in: bounds, size: nil)
            #expect(frame.size == bounds.size)
            #expect(!NewTabSpareParking.frame(in: bounds, size: NSSize(width: 800, height: 600)).intersects(bounds))
            #expect(!frame.intersects(bounds))
            // The window growing later (the parking view keeps its origin) still leaves it outside.
            #expect(!NSRect(origin: frame.origin, size: NSSize(width: 20_000, height: 20_000)).intersects(bounds))
        }
    }

    /// hqacp-v2 proof (120 Hz, 5 runs): for about 40 ms after Cmd-T the page showed at the parked
    /// width, the window content's, wider than its pane (the field ran past the right edge), until
    /// WebKit laid it out at the pane's width. The spare waits at the size of the pane content it
    /// fills, so the adoption changes no size and WebKit has nothing to lay out again.
    @MainActor @Test func theParkedSpareHasThePaneSizeSoTheAdoptionChangesNoSize() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = window.contentView
        // A pane narrower than the window: the sidebar takes the left.
        let pane = PaneContentView(stripModel: TabStripModel())
        pane.frame = NSRect(x: 220, y: 0, width: 880, height: 720)
        content.addSubview(pane)
        pane.layoutSubtreeIfNeeded()
        let target = pane.contentHost.bounds.size
        #expect(target.width == 880 && target.height < 720)

        let parking = NewTabSpareParking(frame: .zero)
        content.addSubview(parking, positioned: .below, relativeTo: nil)
        let spare = NSView(frame: parking.bounds)
        spare.autoresizingMask = [.width, .height]
        parking.addSubview(spare)
        parking.fit(to: target)
        #expect(spare.frame.size == target, "parked at \(spare.frame.size), the pane is \(target)")
        #expect(!parking.frame.intersects(content.bounds), "never under the pointer")
        #expect(NewTabSpareParking.frame(in: content.bounds, size: target).size == target)

        // The adoption: the pane shows the spare at the size it waited at.
        pane.show(spare)
        #expect(spare.superview === pane.contentHost)
        #expect(spare.frame.size == target)
    }
}
