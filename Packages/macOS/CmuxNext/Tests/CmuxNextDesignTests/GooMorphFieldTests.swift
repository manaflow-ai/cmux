import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The goo look's field and trace (Thunderdome r2 C, `GooMorphVariant`): a droplet on a card joins it through a
/// neck with no point, a lone card keeps its own outline, and the leftmost tab sits flush on the card's edge
/// (Leo, 2026-11-05: "the tab, like, presses up right on that divider ... it's completely flush").
struct GooMorphFieldTests {
    private let card = GooShape(rect: CGRect(x: 0, y: 0, width: 400, height: 100), radius: 8, group: 0)

    @Test func aDropletOnItsCardJoinsItThroughANeck() {
        let tab = GooShape(rect: CGRect(x: 100, y: 104, width: 150, height: 24), radius: 12, group: 0)
        let field = GooField(shapes: [card, tab], reach: 22)
        #expect(field.value(175, 102) > 0, "the 4 pt gap under the tab's middle fills")
        #expect(field.value(98, 101) > 0, "the neck flares out past the tab's edge")
        #expect(field.value(60, 110) < 0, "far from the tab the card keeps its own top")
    }

    @Test func aLoneCardKeepsItsOutline() {
        let field = GooField(shapes: [card], reach: 22)
        #expect(field.value(200, 99.5) > 0)
        #expect(field.value(200, 100.5) < 0)
        #expect(field.value(0.5, 99.5) < 0, "the rounded corner stays rounded")
    }

    @Test func groupsMeetWithoutFlowingUntilTheyBlend() {
        let side = GooShape(rect: CGRect(x: -60, y: 0, width: 54, height: 100), radius: 8, group: 1)
        #expect(GooField(shapes: [card, side], reach: 22).value(-3, 50) < 0, "the gutter stays open")
        #expect(GooField(shapes: [card, side], reach: 22, crossBlend: 1).value(-3, 50) > 0, "blended, it fills")
    }

    @Test func theWallCutsTheLeftmostTabFlushOnTheCardsEdge() {
        let tab = GooShape(rect: CGRect(x: -30, y: 104, width: 180, height: 24), radius: 12, group: 0)
        let wall = GooShape(rect: CGRect(x: 0, y: 0, width: 400, height: 128), radius: 0, group: 0)
        let field = GooField(shapes: [card, tab], reach: 22, wall: wall)
        #expect(field.value(0.5, 116) > 0, "the tab runs to the card's edge")
        #expect(field.value(-0.5, 116) < 0, "and not past it")
        #expect(field.value(0.5, 102) > 0, "the edge runs straight up into the tab, no notch")
    }

    @Test func theTraceClosesEveryLoopAndStopsOnThePlainCard() throws {
        let tab = GooShape(rect: CGRect(x: 100, y: 104, width: 150, height: 24), radius: 12, group: 0)
        let field = GooField(shapes: [card, tab], reach: 22)
        let window = tab.rect.insetBy(dx: -24, dy: -24)
        let trace = GooTrace(field: field, plain: [card], windows: [window])
        let loops = trace.loops()
        let loop = try #require(loops.first)
        #expect(loops.count == 1, "the droplet and its neck are one region")
        #expect(loop.allSatisfy { $0.y >= 100 - 0.01 }, "the region stops on the card's top, so it never overlaps it")
        #expect(loop.contains { $0.x < 100 } && loop.contains { $0.x > 250 }, "the neck flares past both sides")
        #expect(!trace.path(loops).isEmpty)
    }
}
