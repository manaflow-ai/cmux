import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// A mouse wheel pages the spaces like a paged scroll view: a notch moves
/// one space, a spinning wheel pages at a steady pace, sideways always pages
/// and up or down pages only where nothing else would scroll.
@Suite struct SpaceWheelPagerTests {
    @Test func aNotchDownOrLeftShowsTheNextSpace() {
        var wheel = SpaceWheelPager()
        #expect(wheel.feed(deltaX: 0, deltaY: -1, time: 1, pagesVertically: true) == .page(1))
        var sideways = SpaceWheelPager()
        #expect(sideways.feed(deltaX: -1, deltaY: 0, time: 1, pagesVertically: false) == .page(1))
    }

    @Test func aNotchUpOrRightShowsThePreviousSpace() {
        var wheel = SpaceWheelPager()
        #expect(wheel.feed(deltaX: 0, deltaY: 1, time: 1, pagesVertically: true) == .page(-1))
        var sideways = SpaceWheelPager()
        #expect(sideways.feed(deltaX: 1, deltaY: 0, time: 1, pagesVertically: false) == .page(-1))
    }

    @Test func aVerticalWheelScrollsTheListWhenRowsOverflow() {
        var wheel = SpaceWheelPager()
        #expect(wheel.feed(deltaX: 0, deltaY: -3, time: 1, pagesVertically: false) == .pass)
    }

    @Test func aSpinningWheelPagesAtMostOncePerInterval() {
        var wheel = SpaceWheelPager()
        #expect(wheel.feed(deltaX: 0, deltaY: -1, time: 1.00, pagesVertically: true) == .page(1))
        #expect(wheel.feed(deltaX: 0, deltaY: -1, time: 1.05, pagesVertically: true) == .hold)
        #expect(wheel.feed(deltaX: 0, deltaY: -1, time: 1.20, pagesVertically: true) == .hold)
        #expect(wheel.feed(deltaX: 0, deltaY: -1, time: 1.00 + SpaceWheelPager.interval, pagesVertically: true) == .page(1))
    }

    @Test func aReverseNotchPagesAtOnce() {
        var wheel = SpaceWheelPager()
        #expect(wheel.feed(deltaX: 0, deltaY: -1, time: 1.00, pagesVertically: true) == .page(1))
        #expect(wheel.feed(deltaX: 0, deltaY: 1, time: 1.05, pagesVertically: true) == .page(-1))
    }
}
