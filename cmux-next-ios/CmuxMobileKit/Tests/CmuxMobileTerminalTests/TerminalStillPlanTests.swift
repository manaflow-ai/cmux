import CoreGraphics
@testable import CmuxMobileTerminal
import Testing

/// qa11 grid-composer-in-card (build 246ef796): the stills behind the grid
/// cards and the saved relaunch frame composed the page's chrome layers
/// (composer, key bar, status bar band) over the rows, and the e2e-t2 card
/// showed the composer across its middle over rows. A still holds the
/// terminal's rows only: the rows between the top inset and the composer
/// card's top, on the terminal background; no chrome layer is drawn.
@Suite struct TerminalStillPlanTests {
    let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)

    @Test func theRowsEndAtTheComposersTop() {
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 62, composerTop: 700)
                == CGRect(x: 0, y: 62, width: 402, height: 638))
        // Keyboard up: the composer sits higher; the rows under it are not shown.
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 62, composerTop: 400)
                == CGRect(x: 0, y: 62, width: 402, height: 338))
    }

    @Test func aComposerOutsideThePageClampsToIt() {
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 0, composerTop: 2000) == bounds)
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 62, composerTop: 10).isEmpty)
    }

    @Test func aStillDrawsNoChrome() {
        #expect(!TerminalStillPlan.drawsChromeLayers)
    }
}

/// qa11 card-a-grid-*: an inactive card drew the Mac's 42-row screen from its
/// top in the page-sized card view, of which TabsKit shows only the top
/// `width * cardAspect` points: rows 21..52 down to the card's edge, and
/// never 53..60, the marker or the prompt. The card shows the screen's last
/// rows that fit, the prompt at the bottom; a short screen stays at the top.
@Suite struct TerminalCardScreenLinesTests {
    let screen = ((21...60).map(String.init) + ["CARD-AFTER-68577", "cmux@cmuxs-Mac-mini-2 ~ %", "", "  "]).joined(separator: "\n")

    @Test func aFullScreenShowsItsLastRowsWithThePrompt() {
        let shown = TerminalCardScreenLines.shown(screen, capacity: 32)
        #expect(shown.count == 32)
        #expect(shown.last == "cmux@cmuxs-Mac-mini-2 ~ %")
        #expect(shown.contains("CARD-AFTER-68577"))
        #expect(shown.first == "31")
    }

    @Test func aShortScreenStaysAtTheTop() {
        #expect(TerminalCardScreenLines.shown("cmux@cmuxs-Mac-mini-2 ~ %\n\n\n", capacity: 32) == ["cmux@cmuxs-Mac-mini-2 ~ %"])
    }

    @Test func theCapacityIsTheVisiblePartOfTheCard() {
        // A 402 pt page card shows 566 pt; 62 pt top inset; 13.2 pt rows.
        let visible = 402 * TerminalCardCrop.cardAspect
        #expect(TerminalCardScreenLines.capacity(visibleHeight: visible, topInset: 62, lineHeight: 13.2) == Int((visible - 62 - 6) / 13.2))
        #expect(TerminalCardScreenLines.capacity(visibleHeight: 10, topInset: 62, lineHeight: 13.2) == 1)
    }
}
