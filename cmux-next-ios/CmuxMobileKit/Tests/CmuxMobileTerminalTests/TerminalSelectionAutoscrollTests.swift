import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// G-14 (T-SEL-01): a handle dragged to an edge of the visible rows scrolls
/// the page, so the selection reaches rows off screen.
@Suite struct TerminalSelectionAutoscrollTests {
    let scroll = TerminalSelectionAutoscroll()

    @Test func theMiddleOfTheScreenDoesNotScroll() {
        #expect(scroll.velocity(fingerY: 400, visibleTop: 100, visibleBottom: 700) == 0)
        #expect(scroll.velocity(fingerY: 100 + scroll.edge + 1, visibleTop: 100, visibleBottom: 700) == 0)
    }

    @Test func nearTheTopTheFingerScrollsTowardOlderRowsFasterAtTheEdge() {
        let inner = scroll.velocity(fingerY: 100 + scroll.edge - 1, visibleTop: 100, visibleBottom: 700)
        let edge = scroll.velocity(fingerY: 100, visibleTop: 100, visibleBottom: 700)
        let past = scroll.velocity(fingerY: 20, visibleTop: 100, visibleBottom: 700)
        #expect(inner < 0)
        #expect(edge < inner)
        #expect(past == -scroll.maxSpeed)
        #expect(abs(inner) >= scroll.minSpeed)
    }

    @Test func nearTheBottomTheFingerScrollsTowardTheNewestRows() {
        let inner = scroll.velocity(fingerY: 700 - scroll.edge + 1, visibleTop: 100, visibleBottom: 700)
        let past = scroll.velocity(fingerY: 860, visibleTop: 100, visibleBottom: 700)
        #expect(inner > 0)
        #expect(past == scroll.maxSpeed)
    }

    @Test func stepsMoveByVelocityTimesTimeAndStopAtTheDocumentEnds() {
        #expect(scroll.step(offset: 1000, velocity: -600, dt: 0.5, range: 0...5000) == 700)
        #expect(scroll.step(offset: 100, velocity: -2400, dt: 0.5, range: 0...5000) == 0)
        #expect(scroll.step(offset: 4900, velocity: 2400, dt: 0.5, range: 0...5000) == 5000)
    }

    @Test func aShortVisibleBandSplitsItsZonesInsteadOfOverlapping() {
        // Keyboard up over a short page: 60 pt of rows, zones of at most 30 pt each.
        #expect(scroll.velocity(fingerY: 129, visibleTop: 100, visibleBottom: 160) < 0)
        #expect(scroll.velocity(fingerY: 131, visibleTop: 100, visibleBottom: 160) > 0)
    }
}
