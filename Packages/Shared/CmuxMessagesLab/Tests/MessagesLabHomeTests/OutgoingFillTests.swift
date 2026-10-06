import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The sent bubble's fill is a gradient layer under the row bitmap (the
/// bitmap holds only the text). Lawrence's 1260 pt Home pane on 2026-10-05
/// (flight recorder blink-20261005-201540: "part:local-3:1 body 1126-1156
/// fill 0-1041") drew a failed send as bare text: the layer spanned only
/// MessagesLab's measured 1041 pt window, so a bubble lower in a taller pane
/// had no fill under it.
@MainActor @Suite(.serialized) struct OutgoingFillTests {
    let me = Fixture2.me

    private func tallPane(height: CGFloat) -> (HomeProjection, ChatController) {
        let (p, c) = Fixture2.projection()
        c.host.frame = NSRect(x: 0, y: 0, width: 628, height: height)
        let failed = TranscriptItem(key: IdempotencyKey("failed"), seq: nil, author: me, parts: [.text("what does this say?")],
                                    createdAt: Fixture2.start.addingTimeInterval(400), delivery: .notDelivered(.invalid("x")))
        p.apply(items: Fixture2.history(4) + [failed], summary: Fixture2.summary(lastSeq: 4), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded()
        c.demo.collection.layoutIfNeeded()
        return (p, c)
    }

    @Test func aFailedSendLowInATallPaneKeepsItsBubbleFill() throws {
        let (_, c) = tallPane(height: 1300)
        let cell = try #require(c.demo.collection.visibleCells.compactMap { $0 as? RowCell }.first { $0.spec?.key == "part:failed:0" })
        let spec = try #require(cell.spec)
        let body = cell.layer.convert(RowDraw.bodyRect(spec), to: c.demo.layer)
        #expect(body.minY > Fixture.gradientHeight, "the row sits below the measured window (\(body.minY))")
        #expect(!cell.fillContainer.isHidden)
        #expect(HomeFlightRecorder.unfilledOutgoing(c.demo).isEmpty, "\(HomeFlightRecorder.unfilledOutgoing(c.demo))")
    }

    @Test func aPaletteChangeKeepsOneLocationPerColour() throws {
        let (_, c) = tallPane(height: 900)
        defer { Fixture.theme = nil }
        let cell = try #require(c.demo.collection.visibleCells.compactMap { $0 as? RowCell }.first { $0.spec?.key == "part:failed:0" })
        let spec = try #require(cell.spec)
        // Measured (8 stops) to a chosen accent (11 stops) on a live cell.
        let theme = HomePalette.Theme(background: .gray255(30), foreground: .gray255(230), accent: .rgb255(200, 30, 30),
                                      failure: .rgb255(255, 69, 58))
        Fixture.theme = FixtureTheme(active: .themed(theme), inactive: .themed(theme, active: false), measuredAccent: false)
        cell.configure(spec)
        let colors = try #require(cell.fillGradient.colors)
        #expect(colors.count == HomePalette.themed(theme).outgoingGradient.count)
        #expect(cell.fillGradient.locations?.count == colors.count)
        Fixture.theme = nil
        cell.configure(spec)
        #expect(cell.fillGradient.colors?.count == Fixture.gradientStops.count)
        #expect(cell.fillGradient.locations?.count == Fixture.gradientStops.count)
    }
}
