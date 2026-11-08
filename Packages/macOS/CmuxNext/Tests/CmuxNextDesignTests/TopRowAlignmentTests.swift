import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The window top's one line (Leo 2026-11-07: "align the top bit of the sidebar with the tabs/vice
/// versa"). The top row's strip starts at the window's top edge under the minimal titlebar; its pill
/// centers on the traffic lights' line wherever the strip holds it (within half a point, the 1x
/// pixel grid's rounding), and otherwise comes as near as the strip and the window's top edge allow.
/// The numbers are the live `debug.top_alignment` values of the `top-alignment` tour on a 1x display.
@Suite struct TopRowAlignmentTests {
    nonisolated struct Mode: CustomTestStringConvertible, Sendable {
        var name: String, strip: CGFloat, tab: CGFloat
        /// The pill center the live capture measured after the change, at 1x.
        var measured: CGFloat
        var testDescription: String { name }
    }

    /// The strip and pill heights each density gave in the capture (Ultra-compact to Spacious).
    nonisolated static let modes: [Mode] = [
        Mode(name: "ultraCompact", strip: 23, tab: 21, measured: 12.5),
        Mode(name: "compact", strip: 28, tab: 24, measured: 16),
        Mode(name: "cozy", strip: 31, tab: 27, measured: 16.5),
        Mode(name: "comfortable", strip: 36, tab: 30, measured: 16),
        Mode(name: "spacious", strip: 41, tab: 35, measured: 18.5),
    ]

    /// The lights' center below the window's top edge, as the capture measured it.
    nonisolated static let lights: CGFloat = 16

    static func center(_ mode: Mode, scale: CGFloat) -> CGFloat {
        TopRowLine(centerY: lights).pillTop(stripTop: 0, stripHeight: mode.strip, tabHeight: mode.tab, scale: scale) + mode.tab / 2
    }

    @Test(arguments: modes) func thePillCentersOnTheLightsLineWhereverTheStripHoldsIt(_ mode: Mode) {
        for scale in [1, 2] as [CGFloat] {
            let center = Self.center(mode, scale: scale)
            let nearest = min(max(Self.lights, TopRowLine.pillMinTopGap + mode.tab / 2), mode.strip - mode.tab / 2)
            #expect(abs(center - nearest) <= 0.5 / scale, "\(mode.name) @\(scale)x: \(center), nearest \(nearest)")
            if nearest == Self.lights { #expect(abs(center - Self.lights) <= 0.5) }
        }
        #expect(Self.center(mode, scale: 1) == mode.measured, "\(mode.name): the live capture measured \(mode.measured)")
    }

    @Test func compactComfortableAndCozyShareTheLine() {
        for name in ["compact", "cozy", "comfortable"] {
            let mode = Self.modes.first { $0.name == name }!
            #expect(abs(Self.center(mode, scale: 2) - Self.lights) <= 0.25, "\(name)")
        }
    }

    @Test func controlsCenterOnTheLineOnThePixelGrid() {
        let line = TopRowLine(centerY: 16.25)
        for side in [20.0, 22, 25, 31] as [CGFloat] {
            let top = line.controlTop(side: side, scale: 2)
            #expect(abs(top + side / 2 - line.centerY) <= 0.25)
            #expect((top * 2).rounded() == top * 2)
        }
    }

    @Test func thePillNeverLeavesItsStripNorTheWindowTop() {
        #expect(TopRowLine(centerY: 40).pillTop(stripTop: 0, stripHeight: 28, tabHeight: 24, scale: 2) == 4)
        #expect(TopRowLine(centerY: 4).pillTop(stripTop: 0, stripHeight: 41, tabHeight: 35, scale: 2) == TopRowLine.pillMinTopGap)
    }

    /// A strip that starts below the window's top (a pane padding, floating panes' gutter) never
    /// moves its pills above its own top: the strip masks its tabs to its bounds (review of #37619:
    /// Compact with `layout.panePadding: 12` asked for -8 and clipped the tabs' upper 8 pt).
    @Test(arguments: modes) func thePillNeverRisesAboveItsStrip(_ mode: Mode) {
        for stripTop in [1, 2, 4, 6, 8, 12, 16, 24] as [CGFloat] {
            for scale in [1, 2] as [CGFloat] {
                let top = TopRowLine(centerY: Self.lights).pillTop(stripTop: stripTop, stripHeight: mode.strip, tabHeight: mode.tab, scale: scale)
                #expect(top >= 0, "\(mode.name) stripTop \(stripTop) @\(scale)x: \(top)")
                #expect(top + mode.tab <= mode.strip, "\(mode.name) stripTop \(stripTop) @\(scale)x: \(top)")
            }
        }
    }

    @Test func aPaddedOrFloatingStripKeepsItsPillsInside() {
        let line = TopRowLine(centerY: 16)
        // Compact with `layout.panePadding: 12`: the strip starts at 12, at or below where the pill would start.
        #expect(line.pillTop(stripTop: 12, stripHeight: 28, tabHeight: 24, scale: 2) == 0)
        // Floating panes: the card (and its strip) start one gutter down.
        #expect(line.pillTop(stripTop: 8, stripHeight: 28, tabHeight: 24, scale: 2) == 0)
        // A small padding still reaches the line: 2 + 2 + 24 / 2 = 16.
        #expect(line.pillTop(stripTop: 2, stripHeight: 28, tabHeight: 24, scale: 2) == 2)
        // Spacious under a 2 pt padding: the window-top gap is already met by the padding.
        #expect(line.pillTop(stripTop: 2, stripHeight: 41, tabHeight: 35, scale: 2) == 0)
    }

    /// Flat chrome with `layout.cornerPadding: 0`: the pill is as tall as its strip, so the window-top gap
    /// cannot fit and containment wins: the pill sits at 0, never 1 pt down with its bottom clipped (review
    /// of #37619). One point of room puts it at 0 or 1, still inside.
    @Test func aPillAsTallAsItsStripStaysInside() {
        for centerY in [4, 12, 16, 30] as [CGFloat] {
            for scale in [1, 2] as [CGFloat] {
                let line = TopRowLine(centerY: centerY)
                #expect(line.pillTop(stripTop: 0, stripHeight: 24, tabHeight: 24, scale: scale) == 0, "line \(centerY) @\(scale)x")
                let roomy = line.pillTop(stripTop: 0, stripHeight: 25, tabHeight: 24, scale: scale)
                #expect(roomy >= 0 && roomy + 24 <= 25, "line \(centerY) @\(scale)x: \(roomy)")
            }
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
                    #expect(line.pillTop(stripTop: stripTop, stripHeight: mode.strip, tabHeight: mode.tab, scale: scale) == metrics.pillTop(scale: scale),
                            "\(mode.name) padding \(padding) @\(scale)x")
                }
            }
        }
    }
}
