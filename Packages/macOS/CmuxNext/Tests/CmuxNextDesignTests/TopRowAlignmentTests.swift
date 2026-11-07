import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The window top's one line (Leo 2026-11-07: "align the top bit of the sidebar with the tabs/vice
/// versa"). The top row's strip starts at the window's top edge under the minimal titlebar; its pill
/// centers on the traffic lights' line wherever the strip holds it (within half a point, the 1x
/// pixel grid's rounding), and otherwise comes as near as the strip and the window's top edge allow.
/// The numbers are the live `debug.top_alignment` values of the `top-alignment` tour on a 1x display.
@Suite struct TopRowAlignmentTests {
    struct Mode: CustomTestStringConvertible, Sendable {
        var name: String, strip: CGFloat, tab: CGFloat
        /// The pill center the live capture measured after the change, at 1x.
        var measured: CGFloat
        var testDescription: String { name }
    }

    /// The strip and pill heights each density gave in the capture (Ultra-compact to Spacious).
    static let modes: [Mode] = [
        Mode(name: "ultraCompact", strip: 23, tab: 21, measured: 12.5),
        Mode(name: "compact", strip: 28, tab: 24, measured: 16),
        Mode(name: "cozy", strip: 31, tab: 27, measured: 16.5),
        Mode(name: "comfortable", strip: 36, tab: 30, measured: 16),
        Mode(name: "spacious", strip: 41, tab: 35, measured: 18.5),
    ]

    /// The lights' center below the window's top edge, as the capture measured it.
    static let lights: CGFloat = 16

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

    @Test func theVariantsResolveTheirOwnLines() {
        #expect(TopRowLine.resolve(.lights, lightsCenterY: 16, stripHeight: 36, titlebarHeight: 40).centerY == 16)
        #expect(TopRowLine.resolve(.off, lightsCenterY: 16, stripHeight: 36, titlebarHeight: 40).centerY == 16)
        #expect(TopRowLine.resolve(.tabs, lightsCenterY: 16, stripHeight: 36, titlebarHeight: 40).centerY == 18)
        #expect(TopRowLine.resolve(.titlebar, lightsCenterY: 16, stripHeight: 36, titlebarHeight: 40).centerY == 20)
    }
}
