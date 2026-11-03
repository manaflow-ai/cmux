import AppKit
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// Every sent-bubble draw in one palette uses the same CGGradient object. CoreGraphics does about 10 µs of work the
/// first time a gradient object draws (OutgoingGradientDrawCostBench: a new gradient per draw cost 10.8 µs more per
/// bubble at p99 than a reused one, fleet step a8c873017d9189e8692656f7), so a palette makes its gradient once.
@MainActor @Suite(.serialized) struct PaletteGradientReuseTests {
    /// A themed palette (a theme accent, not the measured Messages blue) with an 8-stop sent-bubble gradient.
    static func themed() -> FixtureTheme {
        let theme = HomePalette.Theme(background: .gray255(30), foreground: .gray255(230),
                                      accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))
        var palette = HomePalette.iMessageStyled(theme)
        var stops: [HomePalette.GradientStop] = []
        for index in 0..<8 {
            let step = CGFloat(index)
            let location: CGFloat = step / 7
            let red: CGFloat = 90 - 4 * step
            let green: CGFloat = 154 - 2 * step
            let color: HomeColor = .rgb255(red, green, 247)
            stops.append(HomePalette.GradientStop(location: location, color: color))
        }
        palette.outgoingGradient = stops
        return FixtureTheme(active: palette, measuredAccent: false)
    }

    @Test func twoDrawsInOnePaletteUseOneGradient() throws {
        let box = PaletteScope.box(for: Self.themed())
        let first = try #require(PaletteScope.with(box) { Fixture.outgoingGradient })
        let second = try #require(PaletteScope.with(box) { Fixture.outgoingGradient })
        #expect(first === second)
    }
}
