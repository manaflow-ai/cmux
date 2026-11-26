@testable import CmuxVNCWebRTC
import CoreGraphics
import Testing

struct ChangedAreaTests {
    let screen = CGSize(width: 1280, height: 800)

    @Test func aTypedLineEarnsTheFloor() {
        var area = ChangedArea()
        let fraction = area.add([CGRect(x: 640, y: 680, width: 240, height: 24)], in: screen, now: 0)
        #expect(fraction < 0.01)
        #expect(ChangedArea.ceiling(full: 11_000_000, fraction: area.fraction(now: 0)) == ChangedArea.floorBitrate)
    }

    @Test func aQuarterPaneEarnsAQuarter() {
        var area = ChangedArea()
        area.add([CGRect(x: 320, y: 200, width: 640, height: 400)], in: screen, now: 0)
        #expect(area.fraction(now: 0) == 0.25)
        #expect(ChangedArea.ceiling(full: 12_000_000, fraction: 0.25) == 3_000_000)
    }

    @Test func aFullScrollEarnsTheFullCeilingAndNoMore() {
        var area = ChangedArea()
        // Off-screen parts are clipped; overlaps never push past the whole picture.
        area.add([CGRect(x: -100, y: -100, width: 2000, height: 2000), CGRect(origin: .zero, size: screen)], in: screen, now: 0)
        #expect(area.fraction(now: 0) == 1)
        #expect(ChangedArea.ceiling(full: 11_000_000, fraction: 1) == 11_000_000)
        #expect(ChangedArea.ceiling(full: 300_000, fraction: 1) == 300_000)
    }

    @Test func aBigChangeHoldsForTheWindowThenFalls() {
        var area = ChangedArea()
        area.add([CGRect(origin: .zero, size: screen)], in: screen, now: 0)
        area.add([CGRect(x: 0, y: 0, width: 128, height: 80)], in: screen, now: ChangedArea.window / 2)
        #expect(area.fraction(now: ChangedArea.window) == 1)
        #expect(area.fraction(now: ChangedArea.window + 1) == 0.01)
        #expect(area.fraction(now: ChangedArea.window * 3) == 0)
    }

    @Test func updatesOnAnyRiseAndOnlyABigFall() {
        #expect(ChangedArea.worthApplying(1_000_000, over: nil))
        #expect(ChangedArea.worthApplying(1_000_001, over: 1_000_000))
        #expect(!ChangedArea.worthApplying(800_000, over: 1_000_000))
        #expect(ChangedArea.worthApplying(700_000, over: 1_000_000))
    }

    @Test func anEmptyPictureChangesNothing() {
        var area = ChangedArea()
        #expect(area.add([CGRect(x: 0, y: 0, width: 10, height: 10)], in: .zero, now: 0) == 0)
        #expect(area.fraction(now: 0) == 0)
    }
}
