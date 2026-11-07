import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The window top's one line (Leo 2026-11-07: "align the top bit of the sidebar with the tabs/vice
/// versa"): at every density the top row's tab pill centers on the traffic lights' line within half
/// a point, and only where the pill cannot fit under the window's top edge does it stop one point
/// below it. The band's buttons and the sidebar's + center on the same line (`controlTop`).
@Suite struct TopRowAlignmentTests {
    /// One density's pane chrome: the strip, the pill and the pane padding (DensityTokens at the
    /// five built-ins' levels, Ultra-compact to Spacious; #37274 keeps these ids and moves only levels).
    struct Mode: CustomTestStringConvertible, Sendable {
        var name: String, strip: CGFloat, tab: CGFloat, padding: CGFloat
        var testDescription: String { name }
    }

    static let modes: [Mode] = [
        Mode(name: "ultraCompact", strip: 24, tab: 21, padding: 1.5),
        Mode(name: "compact", strip: 28, tab: 24, padding: 2),
        Mode(name: "cozy", strip: 32, tab: 27, padding: 3),
        Mode(name: "comfortable", strip: 36, tab: 30, padding: 4),
        Mode(name: "comfortable (#37274)", strip: 37, tab: 31.5, padding: 4.5),
        Mode(name: "spacious", strip: 42, tab: 35, padding: 5),
        Mode(name: "spacious (#37274)", strip: 44, tab: 37.5, padding: 5),
    ]

    /// macOS draws the lights' center 14 to 16 points below the window's top, by version and style.
    static let lightsCenters: [CGFloat] = [14, 16]
    static let gutter: CGFloat = 6

    /// The pill's center from the window's top, laid out as the app does: the card's top inset
    /// (`WindowTitlebar.cardTopInset`), the pane padding, then the strip's pill top on the line.
    static func pillCenter(_ mode: Mode, lights: CGFloat, look: TopRowLineLook = .lights, scale: CGFloat = 2) -> CGFloat {
        let chrome = PaneChromeMetrics(stripHeight: mode.strip, tabHeight: mode.tab, panePadding: mode.padding)
        let natural = min(gutter, chrome.cardTop(centeringPillOn: lights, scale: scale))
        let line = TopRowLine.resolve(look, lightsCenterY: lights, chrome: chrome, naturalCardTop: natural, titlebarHeight: 40, scale: scale)
        let cardTop = min(gutter, chrome.cardTop(centeringPillOn: line.centerY, scale: scale))
        let stripTop = cardTop + mode.padding
        if look == .off { return stripTop + chrome.pillTop(scale: scale) + mode.tab / 2 }
        return stripTop + line.pillTop(stripTop: stripTop, stripHeight: mode.strip, tabHeight: mode.tab, scale: scale) + mode.tab / 2
    }

    @Test(arguments: modes) func thePillCentersOnTheLightsLineWhereverItFits(_ mode: Mode) {
        for lights in Self.lightsCenters {
            let center = Self.pillCenter(mode, lights: lights)
            if lights - mode.tab / 2 >= TopRowLine.pillMinTopGap {
                #expect(abs(center - lights) <= 0.5, "\(mode.name) lights \(lights): pill center \(center)")
            } else {
                // Too tall to center under the window's top: it stops one point below the edge, the nearest it can come.
                #expect(abs(center - (TopRowLine.pillMinTopGap + mode.tab / 2)) <= 0.5, "\(mode.name) lights \(lights): \(center)")
            }
        }
    }

    @Test func beforeTheFixTheRoomierDensitiesSatBelowTheLine() {
        // The `off` look is the old layout: Cozy and roomier put the pill under the lights' line.
        let spacious = Self.modes.first { $0.name == "spacious" }!
        #expect(Self.pillCenter(spacious, lights: 16, look: .off) - 16 > 5)
        #expect(abs(Self.pillCenter(spacious, lights: 16) - (TopRowLine.pillMinTopGap + spacious.tab / 2)) <= 0.5)
    }

    @Test func controlsCenterOnTheLineOnThePixelGrid() {
        let line = TopRowLine(centerY: 16.25)
        for side in [20.0, 22, 25, 31] as [CGFloat] {
            let top = line.controlTop(side: side, scale: 2)
            #expect(abs(top + side / 2 - line.centerY) <= 0.25)
            #expect((top * 2).rounded() == top * 2)
        }
    }

    @Test func thePillNeverLeavesItsStrip() {
        let line = TopRowLine(centerY: 40)
        #expect(line.pillTop(stripTop: 0, stripHeight: 28, tabHeight: 24, scale: 2) == 4)
    }
}
