import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Leo 2026-11-07: "you could have, like, a gradients option ... the two color gradients, right? And then those
/// eventually, like, go into each other. And of course, you want to make sure you do the thing where they don't become
/// brown ... It maintains its vibrance." The gradient palette's colors blend in OKLCH, so every step keeps its chroma.
struct GroupGradientTests {
    /// The ends are the first and last stops.
    @Test(arguments: GroupGradient.allCases)
    func theEndsAreTheStops(_ gradient: GroupGradient) throws {
        let first = try #require(gradient.stops.first), last = try #require(gradient.stops.last)
        for (place, stop) in [(0.0, first), (1.0, last)] {
            let lch = gradient.rgb(at: place).oklch
            #expect(abs(lch.lightness - stop.lightness) < 0.01, "\(gradient) at \(place): lightness \(lch.lightness)")
            #expect(abs(lch.hue - stop.hue) < 3 || abs(lch.hue - stop.hue) > 357, "\(gradient) at \(place): hue \(lch.hue)")
        }
    }

    /// No step goes grey or brown: every color on the way keeps most of the chroma of the stops around it, where a mix
    /// of the two colors' sRGB channels loses much of it in the middle.
    @Test(arguments: GroupGradient.allCases)
    func everyStepKeepsItsChroma(_ gradient: GroupGradient) {
        let weakest = gradient.stops.map(\.chroma).min() ?? 0
        for step in 0 ... 40 {
            let chroma = gradient.rgb(at: Double(step) / 40).oklch.chroma
            #expect(chroma >= 0.75 * weakest, "\(gradient) step \(step): chroma \(chroma), the stops' least \(weakest)")
        }
    }

    /// The two-tone gradient (purple into orange) runs the short way round, through pink, not through grey: its middle
    /// in OKLCH has far more chroma than the middle of the sRGB mix of its ends.
    @Test func twoToneMixesThroughPinkNotGrey() {
        let middle = GroupGradient.twoTone.rgb(at: 0.5)
        let ends = (GroupGradient.twoTone.rgb(at: 0), GroupGradient.twoTone.rgb(at: 1))
        let srgb = ThemeRGB(red: (ends.0.red + ends.1.red) / 2, green: (ends.0.green + ends.1.green) / 2,
                            blue: (ends.0.blue + ends.1.blue) / 2)
        #expect(middle.oklch.chroma > 1.5 * srgb.oklch.chroma, "OKLCH middle \(middle), sRGB middle \(srgb)")
        let hue = middle.oklch.hue
        #expect(hue > 330 || hue < 20, "the middle is pink-red, hue \(hue)")
    }

    /// Places spread the groups over the whole gradient; a lone group takes the first stop.
    @Test func placesSpreadOverTheWholeGradient() {
        #expect(GroupGradient.place(0, of: 1) == 0)
        #expect((0 ..< 5).map { GroupGradient.place($0, of: 5) } == [0, 0.25, 0.5, 0.75, 1])
    }

    /// A token drawn on its own under the gradient palette takes its place in the palette order, held to the mark
    /// contrast over the sidebar; the gradient palette's marble is eight distinct steps down the gradient.
    @MainActor @Test func tokensAndTheMarbleFollowTheGradient() {
        let tokens = ThemeScope.app.tokens
        let first = GroupColor.paletteOrder[0].paletteRGB(.gradient, tokens: tokens, wallpaper: nil, gradient: .aurora)
        let want = ThemeTokens.readable(GroupGradient.aurora.rgb(at: 0), over: tokens.sidebarBackground,
                                        minimum: ThemeTokens.minimumMarkContrast)
        #expect(first == want)
        let marble = GroupColor.marble(.gradient, tokens: tokens, wallpaper: nil, gradient: .sunset)
        #expect(marble.count == 8)
        #expect(Set(marble).count == 8, "eight steps, each its own color")
    }
}
