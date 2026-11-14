@testable import CmuxNextDesign
import CmuxTheme
import Foundation
import Testing

/// The user, 2026-11-12: "when a new profile is created we should give it a drastically different color (as good as
/// possible)". A new space or browser profile takes the palette color farthest, by eye, from the ones there are.
struct NewProfileColorTests {
    /// OKLab distance between two tokens' vibrant swatches, the smaller of light and dark: two colors must look apart
    /// in both appearances. Computed here on its own, not with the code under test.
    static func distance(_ a: GroupColor, _ b: GroupColor) -> Double {
        func lab(_ hex: UInt32) -> (Double, Double, Double) {
            let lch = ThemeRGB(hex: hex).oklch
            let radians = lch.hue * .pi / 180
            return (lch.lightness, lch.chroma * cos(radians), lch.chroma * sin(radians))
        }
        func apart(_ x: UInt32?, _ y: UInt32?) -> Double {
            let p = lab(x ?? 0), q = lab(y ?? 0)
            return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
        }
        return min(apart(GroupColor.vibrantDark[a], GroupColor.vibrantDark[b]),
                   apart(GroupColor.vibrantLight[a], GroupColor.vibrantLight[b]))
    }

    static func closest(_ colors: [GroupColor]) -> Double {
        var least = Double.infinity
        for (i, a) in colors.enumerated() { for b in colors[(i + 1)...] { least = min(least, distance(a, b)) } }
        return least
    }

    static func made(_ count: Int, after existing: [String] = []) -> [GroupColor] {
        var colors = existing
        var made: [GroupColor] = []
        for _ in 0 ..< count {
            let next = GroupColor.automatic(after: colors)
            made.append(next)
            colors.append(next.rawValue)
        }
        return made
    }

    /// Profiles made one after another stay far apart: the closest two of the first N are at least this far in OKLab.
    /// The thresholds are what the farthest-first choice reaches on the vibrant palette (the old first-unused order
    /// reached 0.182, 0.182, 0.101, 0.101: red then yellow, and pink fourth beside red).
    @Test(arguments: [(2, 0.30), (3, 0.20), (4, 0.18), (5, 0.12)])
    func profilesMadeInARowStayFarApart(_ count: Int, _ threshold: Double) {
        let colors = Self.made(count)
        #expect(Self.closest(colors) >= threshold, "\(colors): closest pair \(Self.closest(colors))")
    }

    /// A profile a person recolored counts: after an orange one, the next is no warm neighbor of orange.
    @Test(arguments: [GroupColor.orange, .red, .pink, .purple, .green, .cyan, .yellow])
    func theNextProfileIsFarFromARecoloredOne(_ picked: GroupColor) {
        let next = GroupColor.automatic(after: [picked.rawValue])
        #expect(Self.distance(next, picked) >= 0.25, "after \(picked): \(next), \(Self.distance(next, picked)) apart")
    }

    /// Past the seven colors a profile still gets one (never none, blue or grey), each round far from the last made.
    @Test func everyProfileGetsAColorNeverBlueOrGrey() {
        let colors = Self.made(15)
        #expect(colors.allSatisfy { $0 != .blue && $0 != .grey })
        #expect(Set(colors.prefix(7)).count == 7)
        for (a, b) in zip(colors, colors.dropFirst()) { #expect(Self.distance(a, b) >= 0.07, "\(a) then \(b)") }
        #expect(Self.made(15) == colors)
    }

    /// No color, or a token this build doesn't know, counts for none.
    @Test func unknownAndMissingColorsCountForNone() {
        #expect(GroupColor.automatic(after: ["", "teal"]) == GroupColor.automatic(after: []))
    }
}
