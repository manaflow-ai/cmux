import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// R99 (Lawrence 2026-10-04): spaces are pages side by side in dot order.
/// A two-finger horizontal scroll moves the sidebar 1:1 with the fingers,
/// rubber-bands past the first and last space, and on release snaps by
/// distance or velocity (a flick goes on, a reverse flick cancels). A switch
/// by dot, key or a new space slides from the side where its dot is.
@Suite struct SpacePagerTests {
    let width: CGFloat = 260

    @Test func theContentFollowsTheFingersOneToOne() {
        var pager = SpacePager(index: 1, count: 3)
        pager.drag(by: -130, width: width)  // fingers left: toward the next space
        #expect(pager.offset == 0.5)
        #expect(pager.neighbor == 2)
        pager.drag(by: 260, width: width)  // and back past the start: the previous space
        #expect(pager.offset == -0.5)
        #expect(pager.neighbor == 0)
    }

    @Test func pastTheLastSpaceItRubberBands() {
        var pager = SpacePager(index: 2, count: 3)
        pager.drag(by: -130, width: width)
        #expect(pager.offset > 0 && pager.offset < 0.5)
        pager.drag(by: -2_000, width: width)
        #expect(pager.offset < 0.2, "the band never shows much past the end")
        #expect(pager.neighbor == nil)
        #expect(pager.target(velocity: -2_000, width: width) == 2, "no space past the end")
    }

    @Test func releaseSnapsByDistanceOrVelocity() {
        var pager = SpacePager(index: 1, count: 3)
        pager.drag(by: -78, width: width)  // 0.3 of a page
        #expect(pager.target(velocity: 0, width: width) == 1, "a short drag returns")
        #expect(pager.target(velocity: -600, width: width) == 2, "a flick toward the next goes on")
        pager.drag(by: -78, width: width)  // 0.6
        #expect(pager.target(velocity: 0, width: width) == 2, "past half goes on")
        #expect(pager.target(velocity: 600, width: width) == 1, "a reverse flick cancels")
    }

    @Test func aSwitchSlidesFromTheSideOfItsDot() {
        #expect(SpacePager.direction(from: 0, to: 3) == 1, "a new space at the end comes from the trailing edge")
        #expect(SpacePager.direction(from: 2, to: 0) == -1)
        #expect(SpacePager.direction(from: 1, to: 1) == 0)
    }
}
