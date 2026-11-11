import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The window top's one line (Leo 2026-11-07: "align the top bit of the sidebar with the tabs/vice
/// versa"). The top row's pill keeps equal gaps above it (from the window's top edge) and below it
/// (to its strip's bottom, the divider under the row, #38054); the main pane's card moves down to
/// bring it onto the traffic lights' line. Where the card cannot (it only moves down, never past the
/// gutter), the line is the pill's own center.
@Suite struct TopRowAlignmentTests {
    nonisolated struct Mode: CustomTestStringConvertible, Sendable {
        var name: String, strip: CGFloat, tab: CGFloat
        var testDescription: String { name }
    }

    /// The strip and pill heights each density gives (Ultra-compact to Spacious).
    nonisolated static let modes: [Mode] = [
        Mode(name: "ultraCompact", strip: 23, tab: 21),
        Mode(name: "compact", strip: 28, tab: 24),
        Mode(name: "cozy", strip: 31, tab: 27),
        Mode(name: "comfortable", strip: 36, tab: 30),
        Mode(name: "spacious", strip: 41, tab: 35),
    ]

    /// The lights' center below the window's top edge, as a live capture measured it, and a line off the 2x grid.
    nonisolated static let lights: [CGFloat] = [16, 16.25]
    /// The main pane gutter's default and the window's lit rim (`WindowTitlebar.topRowCardTop`'s limits).
    static let gutter: CGFloat = 6, rim: CGFloat = 1

    /// The card's top as `WindowTitlebar.topRowCardTop` places it in a titled window.
    static func card(_ metrics: PaneChromeMetrics, line: CGFloat, scale: CGFloat) -> CGFloat {
        let card = max(min(gutter, metrics.cardTop(centeringPillOn: line, scale: scale)), rim)
        return metrics.evenSplitCardTop(card, within: rim...gutter, scale: scale)
    }

    @Test(arguments: modes) func theTopRowPillKeepsEqualGapsAboveAndBelow(_ mode: Mode) {
        for scale in [1, 2] as [CGFloat] {
            for line in Self.lights {
                let metrics = PaneChromeMetrics(stripHeight: mode.strip, tabHeight: mode.tab, panePadding: 0)
                let card = Self.card(metrics, line: line, scale: scale)
                let pill = metrics.pillTop(stripTop: card, scale: scale)
                let above = card + pill, below = mode.strip - mode.tab - pill
                #expect(above == below, "\(mode.name) line \(line) @\(scale)x: card \(card), \(above) above, \(below) below")
                #expect(pill >= 0 && pill + mode.tab <= mode.strip, "\(mode.name) @\(scale)x: inside its strip")
            }
        }
    }

    /// Where the card can move far enough, the pill centers on the lights' line (within a device pixel);
    /// Comfortable and Spacious center lower with the card at the rim, and their line is the pill's.
    @Test(arguments: modes) func thePillReachesTheLightsLineWhereTheCardCanMove(_ mode: Mode) {
        for scale in [1, 2] as [CGFloat] {
            let metrics = PaneChromeMetrics(stripHeight: mode.strip, tabHeight: mode.tab, panePadding: 0)
            let card = Self.card(metrics, line: 16, scale: scale)
            let center = metrics.topRowPillCenter(cardTop: card, scale: scale)
            let reached = TopRowLine(centerY: 16).reached(by: metrics, cardTop: card, scale: scale)
            #expect(reached.centerY == center, "the line the controls read is the pill's")
            switch mode.name {
            case "compact", "cozy": #expect(abs(center - 16) <= 1 / scale, "\(mode.name) @\(scale)x: \(center)")
            case "comfortable", "spacious": #expect(center > 16 && card <= Self.rim + 1 / scale, "\(mode.name) @\(scale)x: \(center)")
            default: #expect(card <= Self.gutter)
            }
        }
    }

    /// The live numbers at 2x: Compact's card drops 4 pt and its pill sits 4 pt from the window's top and
    /// 4 pt above the divider, on the 16 pt line; Comfortable keeps 3.5 pt on each side.
    @Test func compactAndComfortableAt2x() {
        let compact = PaneChromeMetrics(stripHeight: 28, tabHeight: 24, panePadding: 0)
        #expect(compact.cardTop(centeringPillOn: 16, scale: 2) == 4)
        #expect(compact.pillTop(stripTop: 4, scale: 2) == 0)
        #expect(compact.topRowPillCenter(cardTop: 4, scale: 2) == 16)
        let comfortable = PaneChromeMetrics(stripHeight: 36, tabHeight: 30, panePadding: 0)
        #expect(comfortable.cardTop(centeringPillOn: 16, scale: 2) == 0)
        #expect(comfortable.pillTop(stripTop: 1, scale: 2) == 2.5)
    }

    /// Review of #38079: a pill that fills its strip leaves the card at the window's top, `off` and windows with
    /// no top-row strip keep the card formula from before #38054, and a card the gutter clamps on an odd pixel
    /// steps up a pixel instead.
    @Test func theCardsEdgeCases() {
        let full = PaneChromeMetrics(stripHeight: 24, tabHeight: 24, panePadding: 2)
        #expect(full.cardTop(centeringPillOn: 16, scale: 2) == 0)
        let compact = PaneChromeMetrics(stripHeight: 28, tabHeight: 24, panePadding: 0)
        #expect(compact.cardTopKeepingStripCentering(centeringPillOn: 16, scale: 2) == 2, "2 + 2 + 24 / 2 = 16")
        #expect(compact.evenSplitCardTop(3, within: 1...3, scale: 1) == 2, "odd room 1, no room below the gutter: one pixel up")
        #expect(compact.evenSplitCardTop(3, within: 1...6, scale: 1) == 4, "odd room 1: one pixel down")
        #expect(compact.evenSplitCardTop(2, within: 1...6, scale: 1) == 2, "even room: unchanged")
    }

    @Test func controlsCenterOnTheLineOnThePixelGrid() {
        let line = TopRowLine(centerY: 16.25)
        for side in [20.0, 22, 25, 31] as [CGFloat] {
            let top = line.controlTop(side: side, scale: 2)
            #expect(abs(top + side / 2 - line.centerY) <= 0.25)
            #expect((top * 2).rounded() == top * 2)
        }
    }

    /// A strip that starts further below the window's top (a pane padding, floating panes' gutter) never
    /// moves its pills above its own top or past its bottom: the strip masks its tabs to its bounds
    /// (review of #37619: Compact with `layout.panePadding: 12`).
    @Test(arguments: modes) func thePillNeverLeavesItsStrip(_ mode: Mode) {
        let metrics = PaneChromeMetrics(stripHeight: mode.strip, tabHeight: mode.tab, panePadding: 0)
        for stripTop in [0, 1, 2, 4, 6, 8, 12, 16, 24] as [CGFloat] {
            for scale in [1, 2] as [CGFloat] {
                let top = metrics.pillTop(stripTop: stripTop, scale: scale)
                #expect(top >= 0, "\(mode.name) stripTop \(stripTop) @\(scale)x: \(top)")
                #expect(top + mode.tab <= mode.strip, "\(mode.name) stripTop \(stripTop) @\(scale)x: \(top)")
            }
        }
    }

    /// Flat chrome with `layout.cornerPadding: 0`: the pill is as tall as its strip and sits at 0.
    @Test func aPillAsTallAsItsStripStaysInside() {
        for scale in [1, 2] as [CGFloat] {
            #expect(PaneChromeMetrics(stripHeight: 24, tabHeight: 24, panePadding: 0).pillTop(stripTop: 0, scale: scale) == 0)
            let roomy = PaneChromeMetrics(stripHeight: 25, tabHeight: 24, panePadding: 0).pillTop(stripTop: 0, scale: scale)
            #expect(roomy >= 0 && roomy + 24 <= 25, "@\(scale)x: \(roomy)")
        }
    }

    @Test func theVariantsResolveTheirOwnLines() {
        let metrics = PaneChromeMetrics(stripHeight: 36, tabHeight: 30, panePadding: 0)
        let tabs = TopRowLine.tabsCenterY(metrics, scale: 2)
        #expect(tabs == 18)
        #expect(TopRowLine.resolve(.lights, lightsCenterY: 16, tabsCenterY: tabs, titlebarHeight: 40).centerY == 16)
        #expect(TopRowLine.resolve(.off, lightsCenterY: 16, tabsCenterY: tabs, titlebarHeight: 40).centerY == 16)
        #expect(TopRowLine.resolve(.tabs, lightsCenterY: 16, tabsCenterY: tabs, titlebarHeight: 40).centerY == 18)
        #expect(TopRowLine.resolve(.titlebar, lightsCenterY: 16, tabsCenterY: tabs, titlebarHeight: 40).centerY == 20)
    }

    /// The `tabs` line is where the strip's pills already sit on their own padding, so it moves
    /// nothing: the card stays at the window's top and each strip keeps its own pill top (review
    /// of #37619: the line was the strip's bare middle, off by the pane padding).
    @Test func theTabsLineIsWhereTheStripsOwnPaddingPutsThePills() {
        for padding in [0, 2, 6, 12] as [CGFloat] {
            for mode in Self.modes {
                for scale in [1, 2] as [CGFloat] {
                    let metrics = PaneChromeMetrics(stripHeight: mode.strip, tabHeight: mode.tab, panePadding: padding)
                    let line = TopRowLine(centerY: TopRowLine.tabsCenterY(metrics, scale: scale))
                    #expect(metrics.cardTop(centeringPillOn: line.centerY, scale: scale) == 0, "\(mode.name) padding \(padding) @\(scale)x")
                    let stripTop = PaneChromeMetrics.snap(padding, scale)
                    #expect(metrics.pillTop(stripTop: stripTop, scale: scale) == metrics.pillTop(scale: scale),
                            "\(mode.name) padding \(padding) @\(scale)x")
                }
            }
        }
    }
}
