import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The top row's one line on the user's 2x display, at every density (user 2026-11-19, msg 40554: "traffic lights not
/// aligned"). The fleet's test displays are 1x, where a window's line rounds to whole points and an odd-sided control
/// sits half a point off; this holds the window's own line code (``TopRowLine/concentric(_:rim:scale:)``, the lights'
/// ``TrafficLightsLine/placement(centerY:buttonHeight:nativeHeight:scale:)`` and the band's
/// ``TopRowLine/controlTop(side:scale:)``) at scale 2, where every one of them must land on the same 2x pixel.
@MainActor @Suite(.serialized) struct TopRowLineAt2xTests {
    static let scale: CGFloat = 2
    /// macOS's traffic light buttons and the titlebar container it makes for them.
    static let lightHeight: CGFloat = 14, nativeTitlebar: CGFloat = 32

    @Test(arguments: DensityPreset.allCases)
    func theLightsTheBandAndTheTabsShareOne2xLine(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let row = WindowTitlebar.topRowMetrics(scale: Self.scale)
        let rim = PaneTabRowRim.height
        let line = TopRowLine.concentric(row, rim: rim, scale: Self.scale)
        // The first tab: the strip starts under the rim, its pill one strip padding below it.
        let pillTop = rim + row.pillTop(stripTop: rim, rim: rim, scale: Self.scale)
        let pillCenter = pillTop + row.tabHeight / 2
        let gap = row.tabGap(scale: Self.scale)
        #expect(pillTop - rim == gap, "\(preset) @2x: \(pillTop - rim) pt above the first tab, the strip padding is \(gap)")
        #expect(line.centerY == pillCenter, "\(preset) @2x: the line is \(line.centerY), the tab's center \(pillCenter)")
        #expect((line.centerY * Self.scale).rounded() == line.centerY * Self.scale, "\(preset) @2x: the line \(line.centerY) is off the 2x grid")
        // The traffic lights: macOS's 14 pt buttons, moved onto the line.
        let lights = TrafficLightsLine.placement(centerY: line.centerY, buttonHeight: Self.lightHeight, nativeHeight: Self.nativeTitlebar,
                                                 scale: Self.scale)
        #expect(lights.centerY == pillCenter, "\(preset) @2x: the lights center at \(lights.centerY), the tab at \(pillCenter)")
        // The toolbar band's buttons (the sidebar toggle) and the pane's top-row buttons.
        let side = TitlebarBandButton.side
        let bandCenter = line.controlTop(side: side, scale: Self.scale) + side / 2
        #expect(abs(bandCenter - pillCenter) <= 0.25,
                "\(preset) @2x: the band's \(side) pt buttons center at \(bandCenter), the tab at \(pillCenter)")
    }
}
